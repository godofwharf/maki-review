-- Persistent review state for /review, stored in SQLite via the sqlite3 CLI.
--
-- DB: <state_dir>/review/review.db (falls back to ~/.local/state/maki/review
-- when the plugin has no fs_read permission to ask maki for state_dir).
--
-- Every operation is a single sqlite3 invocation; writes run inside
-- BEGIN IMMEDIATE ... COMMIT with a 5s busy timeout, so concurrent humans
-- and agents serialize on the database lock. All strings are embedded as
-- hex blob literals (see q), numbers go through n(); nothing user-supplied
-- is ever spliced into SQL verbatim.

local M = {}

local SQLITE = "/usr/bin/sqlite3"
M.CLAIM_TTL = 1800 -- seconds before an in_progress claim can be taken over

M.ACTIVE = { open = true, in_progress = true }
M.CLOSED = { resolved = true, stale = true, wontfix = true }
M.STATUSES = { "open", "in_progress", "resolved", "stale", "wontfix" }

--- helpers -----------------------------------------------------------------

local function trim(s)
  return ((s or ""):match("^%s*(.-)%s*$"))
end

local function hex(s)
  return (s:gsub(".", function(c)
    return string.format("%02X", string.byte(c))
  end))
end

-- SQL literal for a string (or nil -> NULL).
local function q(v)
  if v == nil then
    return "NULL"
  end
  return "CAST(X'" .. hex(tostring(v)) .. "' AS TEXT)"
end
M.q = q

-- SQL literal for an integer (or nil -> NULL). Errors on non-numbers.
local function n(v)
  if v == nil then
    return "NULL"
  end
  local x = tonumber(v)
  if not x or x ~= x or x == math.huge or x == -math.huge then
    error("expected a number, got " .. tostring(v))
  end
  return string.format("%d", math.floor(x))
end
M.n = n

local function in_list(values)
  local parts = {}
  for _, v in ipairs(values) do
    parts[#parts + 1] = q(v)
  end
  return "(" .. table.concat(parts, ",") .. ")"
end

local NOW = "unixepoch()"

local function tx(body)
  return "BEGIN IMMEDIATE;\n" .. body .. "\nCOMMIT;"
end

--- process plumbing --------------------------------------------------------

local db_dir -- nil = unknown, false = use shell fallback
local function get_dir()
  if db_dir == nil then
    local ok, d = pcall(maki.env.state_dir)
    db_dir = (ok and type(d) == "string" and d ~= "") and (d .. "/review") or false
  end
  return db_dir
end

local SCRIPT = 'd="${MAKI_REVIEW_DIR:-$HOME/.local/state/maki/review}"; '
  .. 'mkdir -p "$d" && exec '
  .. SQLITE
  .. ' -bail -json -cmd ".timeout 5000" "$d/review.db" "$1"'

-- sqlite3 -json prints one JSON array per row-returning statement; the
-- arrays start at a line beginning with "[" (row objects start with "{").
-- We only ever care about the last one.
local function parse(out)
  if not out or not out:find("%S") then
    return {}
  end
  local s, pos = 1, 1
  while true do
    local f = out:find("\n%[", pos)
    if not f then
      break
    end
    s, pos = f + 1, f + 1
  end
  local ok, v, err = pcall(maki.json.decode, out:sub(s))
  if not ok or type(v) ~= "table" then
    return nil, "bad sqlite output: " .. tostring(err or v)
  end
  -- Normalize JSON null (possibly a sentinel value) to nil.
  for _, row in ipairs(v) do
    if type(row) == "table" then
      for k, x in pairs(row) do
        local t = type(x)
        if t ~= "string" and t ~= "number" and t ~= "boolean" then
          row[k] = nil
        end
      end
    end
  end
  return v
end

local function exec_raw(sql)
  local opts = { tail = 0 }
  local d = get_dir()
  if d then
    opts.env = { MAKI_REVIEW_DIR = d }
  end
  local id, err = maki.fn.jobstart(
    { "/bin/sh", "-c", SCRIPT, "sh", "PRAGMA foreign_keys=ON;\n" .. sql },
    opts
  )
  if not id then
    return nil, "sqlite3 failed to start: " .. tostring(err)
  end
  local res, werr = maki.fn.jobwait(id, 20000)
  if not res then
    return nil, "sqlite3: " .. tostring(werr)
  end
  if res.exit_code ~= 0 then
    local e = trim(res.stderr)
    return nil, e ~= "" and e or ("sqlite3 exit " .. tostring(res.exit_code))
  end
  return parse(res.stdout)
end

--- schema ------------------------------------------------------------------

local MIGRATIONS = {
  [[
CREATE TABLE IF NOT EXISTS reviews(
  id TEXT PRIMARY KEY,
  repo_root TEXT NOT NULL,
  remote_name TEXT,
  remote_url TEXT,
  worktree_path TEXT NOT NULL,
  branch TEXT NOT NULL,
  head_at_start TEXT,
  title TEXT,
  status TEXT NOT NULL DEFAULT 'open' CHECK(status IN('open','resolved','deleted')),
  created_by_kind TEXT NOT NULL CHECK(created_by_kind IN('human','agent')),
  created_by_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  resolved_at INTEGER,
  deleted_at INTEGER
);
CREATE UNIQUE INDEX IF NOT EXISTS one_open ON reviews(repo_root, worktree_path, branch) WHERE status='open';
CREATE INDEX IF NOT EXISTS r_repo ON reviews(repo_root, status);
CREATE TABLE IF NOT EXISTS comments(
  id TEXT PRIMARY KEY,
  review_id TEXT NOT NULL REFERENCES reviews(id) ON DELETE CASCADE,
  file_path TEXT NOT NULL,
  target_kind TEXT NOT NULL CHECK(target_kind IN('worktree','commit')),
  target_sha TEXT,
  side TEXT NOT NULL DEFAULT 'new' CHECK(side IN('new','old')),
  span_from INTEGER,
  span_to INTEGER,
  snippet TEXT,
  anchor_json TEXT,
  blob_sha TEXT,
  body TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK(status IN('open','in_progress','resolved','stale','wontfix')),
  author_kind TEXT NOT NULL CHECK(author_kind IN('human','agent')),
  author_id TEXT NOT NULL,
  added_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  claimed_by TEXT,
  claimed_at INTEGER,
  resolved_by_kind TEXT,
  resolved_by_id TEXT,
  resolved_at INTEGER,
  resolution_note TEXT,
  resolution_sha TEXT,
  version INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS c_review_status ON comments(review_id, status);
CREATE INDEX IF NOT EXISTS c_review_file ON comments(review_id, file_path);
CREATE TABLE IF NOT EXISTS comment_events(
  id INTEGER PRIMARY KEY,
  comment_id TEXT NOT NULL REFERENCES comments(id) ON DELETE CASCADE,
  at INTEGER NOT NULL,
  actor_kind TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  from_status TEXT,
  to_status TEXT,
  note TEXT
);
CREATE INDEX IF NOT EXISTS e_comment ON comment_events(comment_id);
CREATE TABLE IF NOT EXISTS prefs(key TEXT PRIMARY KEY, value TEXT);
]],
}

local migrated = false

function M.migrate()
  if migrated then
    return true
  end
  local _, err = exec_raw("PRAGMA journal_mode=WAL;")
  if err then
    return nil, err
  end
  local rows
  rows, err = exec_raw(
    "CREATE TABLE IF NOT EXISTS schema_version(version INTEGER NOT NULL);"
      .. "SELECT COALESCE(MAX(version),0) AS v FROM schema_version;"
  )
  if not rows then
    return nil, err
  end
  local v = tonumber(rows[1] and rows[1].v) or 0
  for i = v + 1, #MIGRATIONS do
    -- Idempotent DDL + guarded version insert: safe if two processes race.
    local _, merr = exec_raw(tx(
      MIGRATIONS[i]
        .. "\nINSERT INTO schema_version(version) SELECT "
        .. n(i)
        .. " WHERE NOT EXISTS (SELECT 1 FROM schema_version WHERE version="
        .. n(i)
        .. ");"
    ))
    if merr then
      return nil, "migration " .. i .. ": " .. merr
    end
  end
  migrated = true
  return true
end

local function exec(sql)
  local ok, err = M.migrate()
  if not ok then
    return nil, err
  end
  return exec_raw(sql)
end
M.exec = exec

--- scope / identity --------------------------------------------------------

local SCOPE_SCRIPT = [[
git rev-parse --path-format=absolute --show-toplevel --git-common-dir || exit 1
echo "B:$(git branch --show-current 2>/dev/null)"
echo "H:$(git rev-parse HEAD 2>/dev/null)"
r=$(git remote 2>/dev/null | grep -x origin || git remote 2>/dev/null | head -n1)
echo "R:$r"
if [ -n "$r" ]; then echo "U:$(git remote get-url "$r" 2>/dev/null)"; else echo "U:"; fi
echo "E:$(git config user.email 2>/dev/null)"
echo "N:$(id -un 2>/dev/null)"
]]

-- Runs a shell script (argv, no interpolation of our values), returns stdout.
local function sh(script, cwd, ...)
  local argv = { "/bin/sh", "-c", script, "sh", ... }
  local id, err = maki.fn.jobstart(argv, { cwd = cwd })
  if not id then
    return nil, tostring(err)
  end
  local res, werr = maki.fn.jobwait(id, 15000)
  if not res then
    return nil, tostring(werr)
  end
  if res.exit_code ~= 0 then
    local e = trim(res.stderr)
    return nil, e ~= "" and e or ("exit " .. tostring(res.exit_code))
  end
  return res.stdout or ""
end
M.sh = sh

-- Scope of the git worktree containing `cwd`:
-- { repo_root, worktree_path, branch, head, remote_name, remote_url, user }
function M.scope(cwd)
  local out, err = sh(SCOPE_SCRIPT, cwd)
  if not out then
    return nil, "not a git repository (" .. tostring(err) .. ")"
  end
  local lines = {}
  for l in (out .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = l
  end
  local top, common = lines[1], lines[2]
  if not top or top == "" or not common then
    return nil, "could not resolve git worktree"
  end
  local kv = {}
  for _, l in ipairs(lines) do
    local k, v = l:match("^(%u):(.*)$")
    if k then
      kv[k] = v
    end
  end
  local repo_root = common:gsub("/+$", "")
  repo_root = repo_root:match("^(.*)/%.git$") or repo_root
  local head = kv.H ~= "" and kv.H or nil
  local branch = kv.B
  if not branch or branch == "" then
    branch = "detached@" .. (head and head:sub(1, 12) or "unborn")
  end
  local user = (kv.E ~= "" and kv.E) or (kv.N ~= "" and kv.N) or "human"
  return {
    repo_root = repo_root,
    worktree_path = top,
    branch = branch,
    head = head,
    remote_name = kv.R ~= "" and kv.R or nil,
    remote_url = kv.U ~= "" and kv.U or nil,
    user = user,
  }
end

function M.same_scope(review, scope)
  return review
    and scope
    and review.repo_root == scope.repo_root
    and review.worktree_path == scope.worktree_path
    and review.branch == scope.branch
end

-- Restricts a comments query to reviews in `scope` (nil = unrestricted).
local function guard(scope, col)
  if not scope then
    return ""
  end
  return " AND "
    .. (col or "review_id")
    .. " IN (SELECT id FROM reviews WHERE repo_root="
    .. q(scope.repo_root)
    .. " AND worktree_path="
    .. q(scope.worktree_path)
    .. " AND branch="
    .. q(scope.branch)
    .. ")"
end

local function scope_where(scope, alias)
  local p = alias and (alias .. ".") or ""
  return p
    .. "repo_root="
    .. q(scope.repo_root)
    .. " AND "
    .. p
    .. "worktree_path="
    .. q(scope.worktree_path)
    .. " AND "
    .. p
    .. "branch="
    .. q(scope.branch)
end

--- decoding ----------------------------------------------------------------

-- Adds anchor fields (new_start/new_end/old_start/old_end) from anchor_json.
function M.decode_comment(row)
  if row.anchor_json and row.anchor_json ~= "" then
    local ok, a = pcall(maki.json.decode, row.anchor_json)
    if ok and type(a) == "table" then
      row.new_start, row.new_end = a.new_start, a.new_end
      row.old_start, row.old_end = a.old_start, a.old_end
    end
  end
  return row
end

--- reviews -----------------------------------------------------------------

local REVIEW_COLS = [[r.*,
  (SELECT COUNT(*) FROM comments c WHERE c.review_id=r.id) AS n_total,
  (SELECT COUNT(*) FROM comments c WHERE c.review_id=r.id AND c.status IN('open','in_progress')) AS n_active]]

local function one(rows, err)
  if not rows then
    return nil, err
  end
  return rows[1]
end

function M.get_review(id)
  return one(exec("SELECT " .. REVIEW_COLS .. " FROM reviews r WHERE r.id=" .. q(id) .. ";"))
end

-- Open review for `scope`; creates one when `create` and none exists.
function M.open_review(scope, actor, create)
  local sel = "SELECT " .. REVIEW_COLS .. " FROM reviews r WHERE " .. scope_where(scope, "r")
    .. " AND r.status='open';"
  if not create then
    return one(exec(sel))
  end
  return one(exec(tx(
    "INSERT INTO reviews(id,repo_root,remote_name,remote_url,worktree_path,branch,head_at_start,"
      .. "title,status,created_by_kind,created_by_id,created_at,updated_at) SELECT lower(hex(randomblob(6))),"
      .. table.concat({
        q(scope.repo_root),
        q(scope.remote_name),
        q(scope.remote_url),
        q(scope.worktree_path),
        q(scope.branch),
        q(scope.head),
        q(scope.branch),
        "'open'",
        q(actor.kind),
        q(actor.id),
        NOW,
        NOW,
      }, ",")
      .. " WHERE NOT EXISTS (SELECT 1 FROM reviews WHERE "
      .. scope_where(scope)
      .. " AND status='open');\n"
      .. sel
  )))
end

-- Reopens a resolved review unless its scope already has another open one.
function M.reopen_review(id)
  return one(exec(tx(
    "UPDATE reviews SET status='open', resolved_at=NULL, updated_at="
      .. NOW
      .. " WHERE id="
      .. q(id)
      .. " AND status='resolved' AND NOT EXISTS (SELECT 1 FROM reviews r2 WHERE"
      .. " r2.repo_root=reviews.repo_root AND r2.worktree_path=reviews.worktree_path"
      .. " AND r2.branch=reviews.branch AND r2.status='open');\n"
      .. "SELECT "
      .. REVIEW_COLS
      .. " FROM reviews r WHERE r.id="
      .. q(id)
      .. ";"
  )))
end

-- opts: { repo_root?, scope?, include_hidden? }
function M.list_reviews(opts)
  opts = opts or {}
  local where = { "1=1" }
  if opts.scope then
    where[#where + 1] = scope_where(opts.scope, "r")
  elseif opts.repo_root then
    where[#where + 1] = "r.repo_root=" .. q(opts.repo_root)
  end
  if not opts.include_hidden then
    where[#where + 1] = "r.status='open'"
  end
  return exec(
    "SELECT "
      .. REVIEW_COLS
      .. " FROM reviews r WHERE "
      .. table.concat(where, " AND ")
      .. " ORDER BY r.updated_at DESC, r.created_at DESC;"
  )
end

local function set_review_status(id, to, extra)
  local rows, err = exec(tx(
    "UPDATE reviews SET status="
      .. q(to)
      .. ", updated_at="
      .. NOW
      .. extra
      .. " WHERE id="
      .. q(id)
      .. " AND status<>"
      .. q(to)
      .. ";\nSELECT changes() AS changed;"
  ))
  if not rows then
    return nil, err
  end
  return (tonumber(rows[1] and rows[1].changed) or 0) > 0
end

function M.mark_review_resolved(id)
  return set_review_status(id, "resolved", ", resolved_at=" .. NOW)
end

function M.soft_delete_review(id)
  return set_review_status(id, "deleted", ", deleted_at=" .. NOW)
end

-- SQL that flips review `rid_expr` to resolved when it has comments and
-- none of them is open/in_progress.
local function autoresolve_sql(rid_expr)
  return "UPDATE reviews SET status='resolved', resolved_at="
    .. NOW
    .. ", updated_at="
    .. NOW
    .. " WHERE id="
    .. rid_expr
    .. " AND status='open' AND EXISTS (SELECT 1 FROM comments WHERE review_id="
    .. rid_expr
    .. ") AND NOT EXISTS (SELECT 1 FROM comments WHERE review_id="
    .. rid_expr
    .. " AND status IN('open','in_progress'));\n"
end

local function touch_review_sql(rid_expr)
  return "UPDATE reviews SET updated_at=" .. NOW .. " WHERE id=" .. rid_expr .. ";\n"
end

--- comments ----------------------------------------------------------------

-- filter: { statuses = {...}?, file = "path"? }
function M.list_comments(review_id, filter)
  filter = filter or {}
  local where = "review_id=" .. q(review_id)
  if filter.statuses and #filter.statuses > 0 then
    where = where .. " AND status IN " .. in_list(filter.statuses)
  end
  if filter.file then
    where = where .. " AND file_path=" .. q(filter.file)
  end
  local rows, err =
    exec("SELECT * FROM comments WHERE " .. where .. " ORDER BY added_at, rowid;")
  if not rows then
    return nil, err
  end
  for _, r in ipairs(rows) do
    M.decode_comment(r)
  end
  return rows
end

function M.get_comment(id, scope)
  local row, err = one(exec("SELECT * FROM comments WHERE id=" .. q(id) .. guard(scope) .. ";"))
  if row then
    M.decode_comment(row)
  end
  return row, err
end

function M.events(comment_id)
  return exec(
    "SELECT * FROM comment_events WHERE comment_id=" .. q(comment_id) .. " ORDER BY id;"
  )
end

-- f: { file_path, target_kind, target_sha?, side, span_from, span_to,
--      snippet?, anchor = {new_start,...}?, blob_sha?, body }
-- Reopens the review if it was auto-resolved (fails if its scope already has
-- another open review). Returns the new comment row.
function M.add_comment(review_id, f, actor)
  local anchor = f.anchor and maki.json.encode(f.anchor) or nil
  local rid = q(review_id)
  local rows, err = exec(tx(
    "CREATE TEMP TABLE _new AS SELECT lower(hex(randomblob(6))) AS id;\n"
      .. "UPDATE reviews SET status='open', resolved_at=NULL WHERE id="
      .. rid
      .. " AND status='resolved';\n"
      .. "INSERT INTO comments(id,review_id,file_path,target_kind,target_sha,side,span_from,span_to,"
      .. "snippet,anchor_json,blob_sha,body,status,author_kind,author_id,added_at,updated_at) SELECT "
      .. table.concat({
        "(SELECT id FROM _new)",
        rid,
        q(f.file_path),
        q(f.target_kind or "worktree"),
        q(f.target_sha),
        q(f.side or "new"),
        n(f.span_from),
        n(f.span_to),
        q(f.snippet),
        q(anchor),
        q(f.blob_sha),
        q(f.body),
        "'open'",
        q(actor.kind),
        q(actor.id),
        NOW,
        NOW,
      }, ",")
      .. " WHERE EXISTS (SELECT 1 FROM reviews WHERE id="
      .. rid
      .. " AND status='open');\n"
      .. "INSERT INTO comment_events(comment_id,at,actor_kind,actor_id,from_status,to_status,note)"
      .. " SELECT id,"
      .. NOW
      .. ","
      .. q(actor.kind)
      .. ","
      .. q(actor.id)
      .. ",NULL,'open','created' FROM comments WHERE id=(SELECT id FROM _new);\n"
      .. touch_review_sql(rid)
      .. "SELECT * FROM comments WHERE id=(SELECT id FROM _new);"
  ))
  if not rows then
    return nil, err
  end
  if not rows[1] then
    return nil, "review is not open"
  end
  return M.decode_comment(rows[1])
end

-- Result of a guarded mutation: true, or false + reason when nothing changed.
local function changed_result(rows, err)
  if not rows then
    return nil, err
  end
  local r = rows[1] or {}
  if (tonumber(r.changed) or 0) > 0 then
    return true, r
  end
  return false, r
end

-- Edits the body of one of `actor`'s own active comments.
function M.edit_comment(id, body, version, actor)
  local cid = q(id)
  local rows, err = exec(tx(
    "CREATE TEMP TABLE _c AS SELECT id, review_id, status FROM comments WHERE id=" .. cid .. ";\n"
      .. "UPDATE comments SET body="
      .. q(body)
      .. ", updated_at="
      .. NOW
      .. ", version=version+1 WHERE id="
      .. cid
      .. (version and (" AND version=" .. n(version)) or "")
      .. " AND author_kind="
      .. q(actor.kind)
      .. " AND author_id="
      .. q(actor.id)
      .. " AND status IN('open','in_progress');\n"
      .. "CREATE TEMP TABLE _r AS SELECT changes() AS n;\n"
      .. "INSERT INTO comment_events(comment_id,at,actor_kind,actor_id,from_status,to_status,note)"
      .. " SELECT id,"
      .. NOW
      .. ","
      .. q(actor.kind)
      .. ","
      .. q(actor.id)
      .. ",status,status,'edited' FROM _c WHERE (SELECT n FROM _r)=1;\n"
      .. "SELECT n AS changed FROM _r;"
  ))
  return changed_result(rows, err)
end

-- Hard-deletes one of `actor`'s own comments while it is still open.
function M.delete_comment(id, actor)
  local cid = q(id)
  local rows, err = exec(tx(
    "CREATE TEMP TABLE _c AS SELECT review_id FROM comments WHERE id=" .. cid .. ";\n"
      .. "DELETE FROM comments WHERE id="
      .. cid
      .. " AND author_kind="
      .. q(actor.kind)
      .. " AND author_id="
      .. q(actor.id)
      .. " AND status='open';\n"
      .. "CREATE TEMP TABLE _r AS SELECT changes() AS n;\n"
      .. autoresolve_sql("(SELECT review_id FROM _c)")
      .. "SELECT n AS changed FROM _r;"
  ))
  return changed_result(rows, err)
end

-- Changes a comment's status, recording an event.
-- opts: { note?, sha?, version?, scope?, respect_claim? }
--   version       optimistic check (UI passes the version it rendered)
--   scope         restricts to comments of reviews in that scope (tools)
--   respect_claim refuse when someone else holds a live in_progress claim
function M.set_status(id, to, actor, opts)
  opts = opts or {}
  if not (M.ACTIVE[to] or M.CLOSED[to]) or to == "in_progress" then
    return nil, "invalid status: " .. tostring(to)
  end
  local cid = q(id)
  local closed = M.CLOSED[to] and true or false
  local where = " WHERE id=" .. cid .. " AND status<>" .. q(to) .. guard(opts.scope)
  if opts.version then
    where = where .. " AND version=" .. n(opts.version)
  end
  if opts.respect_claim then
    where = where
      .. " AND NOT (status='in_progress' AND claimed_by IS NOT NULL AND claimed_by<>"
      .. q(actor.id)
      .. " AND claimed_at >= "
      .. NOW
      .. "-"
      .. n(M.CLAIM_TTL)
      .. ")"
  end
  local set
  if closed then
    set = "resolved_by_kind="
      .. q(actor.kind)
      .. ", resolved_by_id="
      .. q(actor.id)
      .. ", resolved_at="
      .. NOW
      .. ", resolution_note="
      .. q(opts.note)
      .. ", resolution_sha="
      .. q(opts.sha)
  else
    set = "resolved_by_kind=NULL, resolved_by_id=NULL, resolved_at=NULL, resolution_note=NULL, resolution_sha=NULL"
  end
  local rows, err = exec(tx(
    "CREATE TEMP TABLE _c AS SELECT id, review_id, status FROM comments WHERE id=" .. cid .. ";\n"
      .. "UPDATE comments SET status="
      .. q(to)
      .. ", "
      .. set
      .. ", claimed_by=NULL, claimed_at=NULL, updated_at="
      .. NOW
      .. ", version=version+1"
      .. where
      .. ";\n"
      .. "CREATE TEMP TABLE _r AS SELECT changes() AS n;\n"
      .. "INSERT INTO comment_events(comment_id,at,actor_kind,actor_id,from_status,to_status,note)"
      .. " SELECT id,"
      .. NOW
      .. ","
      .. q(actor.kind)
      .. ","
      .. q(actor.id)
      .. ",status,"
      .. q(to)
      .. ","
      .. q(opts.note)
      .. " FROM _c WHERE (SELECT n FROM _r)=1;\n"
      .. (closed and "" or (
        "UPDATE reviews SET status='open', resolved_at=NULL WHERE id=(SELECT review_id FROM _c)"
          .. " AND status='resolved' AND (SELECT n FROM _r)=1 AND NOT EXISTS (SELECT 1 FROM reviews r2"
          .. " WHERE r2.repo_root=reviews.repo_root AND r2.worktree_path=reviews.worktree_path"
          .. " AND r2.branch=reviews.branch AND r2.status='open');\n"
      ))
      .. touch_review_sql("(SELECT review_id FROM _c)")
      .. autoresolve_sql("(SELECT review_id FROM _c)")
      .. "SELECT n AS changed, (SELECT status FROM reviews WHERE id=(SELECT review_id FROM _c))"
      .. " AS review_status, (SELECT status FROM comments WHERE id="
      .. cid
      .. ") AS status, (SELECT claimed_by FROM comments WHERE id="
      .. cid
      .. ") AS claimed_by FROM _r;"
  ))
  return changed_result(rows, err)
end

-- Claims an open comment (or takes over an expired / own claim).
function M.claim(id, actor, scope)
  local cid = q(id)
  local rows, err = exec(tx(
    "CREATE TEMP TABLE _c AS SELECT id, review_id, status FROM comments WHERE id=" .. cid .. ";\n"
      .. "UPDATE comments SET status='in_progress', claimed_by="
      .. q(actor.id)
      .. ", claimed_at="
      .. NOW
      .. ", updated_at="
      .. NOW
      .. ", version=version+1 WHERE id="
      .. cid
      .. guard(scope)
      .. " AND (status='open' OR (status='in_progress' AND (claimed_by IS NULL OR claimed_by="
      .. q(actor.id)
      .. " OR claimed_at < "
      .. NOW
      .. "-"
      .. n(M.CLAIM_TTL)
      .. ")));\n"
      .. "CREATE TEMP TABLE _r AS SELECT changes() AS n;\n"
      .. "INSERT INTO comment_events(comment_id,at,actor_kind,actor_id,from_status,to_status,note)"
      .. " SELECT id,"
      .. NOW
      .. ","
      .. q(actor.kind)
      .. ","
      .. q(actor.id)
      .. ",status,'in_progress','claimed' FROM _c WHERE (SELECT n FROM _r)=1;\n"
      .. touch_review_sql("(SELECT review_id FROM _c)")
      .. "SELECT n AS changed, (SELECT status FROM comments WHERE id="
      .. cid
      .. ") AS status, (SELECT claimed_by FROM comments WHERE id="
      .. cid
      .. ") AS claimed_by FROM _r;"
  ))
  return changed_result(rows, err)
end

-- Releases `actor`'s claim, putting the comment back to open.
function M.release(id, actor, scope, note)
  local cid = q(id)
  local rows, err = exec(tx(
    "CREATE TEMP TABLE _c AS SELECT id, review_id, status FROM comments WHERE id=" .. cid .. ";\n"
      .. "UPDATE comments SET status='open', claimed_by=NULL, claimed_at=NULL, updated_at="
      .. NOW
      .. ", version=version+1 WHERE id="
      .. cid
      .. guard(scope)
      .. " AND status='in_progress' AND claimed_by="
      .. q(actor.id)
      .. ";\n"
      .. "CREATE TEMP TABLE _r AS SELECT changes() AS n;\n"
      .. "INSERT INTO comment_events(comment_id,at,actor_kind,actor_id,from_status,to_status,note)"
      .. " SELECT id,"
      .. NOW
      .. ","
      .. q(actor.kind)
      .. ","
      .. q(actor.id)
      .. ",status,'open',"
      .. q(note or "released")
      .. " FROM _c WHERE (SELECT n FROM _r)=1;\n"
      .. "SELECT n AS changed, (SELECT status FROM comments WHERE id="
      .. cid
      .. ") AS status, (SELECT claimed_by FROM comments WHERE id="
      .. cid
      .. ") AS claimed_by FROM _r;"
  ))
  return changed_result(rows, err)
end

--- prefs -------------------------------------------------------------------

function M.get_prefs()
  local rows, err = exec("SELECT key, value FROM prefs;")
  if not rows then
    return nil, err
  end
  local p = {}
  for _, r in ipairs(rows) do
    p[r.key] = r.value
  end
  return p
end

function M.set_pref(key, value)
  local _, err = exec(
    "INSERT INTO prefs(key,value) VALUES("
      .. q(key)
      .. ","
      .. q(tostring(value))
      .. ") ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
  )
  return err == nil, err
end

return M
