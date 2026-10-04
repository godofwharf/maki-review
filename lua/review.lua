-- /review: review maki's changes with inline comments.
--
-- Layout: a left column of three stacked panels + a right pane.
--   * Files    — changed files vs HEAD (staged, unstaged, untracked),
--     shown as a directory tree; Enter/l toggles a directory, h collapses.
--   * Commits  — recent commits; Enter drills into a commit's files (tree).
--   * Comments — every review comment written so far (d deletes).
--   * Right: syntax-highlighted diff of the selected file (previewed live),
--     or the commit summary / comment detail for the other panels.
--   * Tab cycles the left panels; Enter/l focuses the diff, h/Esc goes back.
--     In the diff: `c` comments the current line, `v` selects a range first,
--     `d` deletes a comment.
--   * `s` submits all comments to a new focused maki session that fixes them.
--
-- After every turn, a status flash reminds you when files changed.
--
-- Rendering notes:
--   * The cursor row is drawn manually (padded to full width and restyled)
--     instead of relying on the host's `cursor_line`, because span
--     backgrounds (diff tints) patch over the native highlight.
--   * Only the Files window is ever focused; it receives all keys. The
--     "active pane" is plugin state, indicated by a double border, a ▶title◀
--     marker, and dimmed text in the inactive left panels.

local TextInput = require("maki.text_input")

local COMMENT_MARK = "● "
local COMMENT_BAR = "    ┃ "
local NO_CHANGES = "  Working tree clean."

-- Blend fractions for diff line background tints.
local ADD_TINT = { "#3fb950", 0.18 }
local DEL_TINT = { "#f85149", 0.18 }
local SEL_TINT = { "#58a6ff", 0.30 }
local COM_TINT = { "#e3b341", 0.22 }

-- One shared comment store per maki process, survives window close/reopen.
-- Entry: { file, text, anchor ("new"|"old"), new_start, new_end,
--          old_start, old_end, snippet }
local comments = {}

-- Diff layout, shared across reviews: false = unified, true = side by side.
local split_view = false
-- Diff context, shared across reviews: false = hunks only, true = whole file.
local full_file = false

--- shell helpers -----------------------------------------------------------

local function sh_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Runs a shell command, returns trimmed stdout or nil, err.
local function run(cmd)
  local id = maki.fn.jobstart(cmd)
  local res = maki.fn.jobwait(id, 15000)
  if not res then
    return nil, "timed out: " .. cmd
  end
  -- git diff exits 1 when files differ (--no-index); only treat >1 as failure.
  if res.exit_code > 1 then
    local err = (res.stderr or ""):match("^%s*(.-)%s*$")
    return nil, err ~= "" and err or ("exit " .. res.exit_code)
  end
  return res.stdout or ""
end

--- colors ------------------------------------------------------------------

local function hex_rgb(hex)
  local h = hex:gsub("#", "")
  return tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16)
end

-- Mix color `top` into `base` by fraction t (0..1). Both "#rrggbb".
local function blend(base, top, t)
  local br, bg_, bb = hex_rgb(base)
  local tr, tg, tb = hex_rgb(top)
  return string.format(
    "#%02x%02x%02x",
    math.floor(br + (tr - br) * t + 0.5),
    math.floor(bg_ + (tg - bg_) * t + 0.5),
    math.floor(bb + (tb - bb) * t + 0.5)
  )
end

local tints -- { add, del, sel } computed lazily from the theme background
local function get_tints()
  if tints then
    return tints
  end
  local bg = maki.ui.theme_color("background")
  if not bg then
    tints = {}
    return tints
  end
  tints = {
    add = blend(bg, ADD_TINT[1], ADD_TINT[2]),
    del = blend(bg, DEL_TINT[1], DEL_TINT[2]),
    sel = blend(bg, SEL_TINT[1], SEL_TINT[2]),
    com = blend(bg, COM_TINT[1], COM_TINT[2]),
  }
  return tints
end

--- git plumbing ------------------------------------------------------------

local function comment_count(change)
  local n = 0
  for _, c in ipairs(comments) do
    if c.file == change.path and c.commit == change.commit then
      n = n + 1
    end
  end
  return n
end

-- Returns array of { path, status, adds, dels, untracked, binary } or nil, err.
local function git_changes()
  local ok, err = run("git rev-parse --is-inside-work-tree")
  if not ok then
    return nil, "not a git repository (" .. tostring(err) .. ")"
  end

  local changes, seen = {}, {}

  local ns = run("git diff --no-color --name-status HEAD") or ""
  for line in ns:gmatch("[^\n]+") do
    local status, rest = line:match("^(%S+)\t(.+)$")
    if status then
      local path = rest:match("\t(.+)$") or rest -- renames: keep new path
      seen[path] = #changes + 1
      changes[#changes + 1] =
        { path = path, status = status:sub(1, 1), adds = 0, dels = 0 }
    end
  end

  local numstat = run("git diff --no-color --numstat HEAD") or ""
  for line in numstat:gmatch("[^\n]+") do
    local adds, dels, path = line:match("^(%S+)\t(%S+)\t(.+)$")
    if path then
      local idx = seen[path]
      if idx then
        if adds == "-" then
          changes[idx].binary = true
        else
          changes[idx].adds = tonumber(adds) or 0
          changes[idx].dels = tonumber(dels) or 0
        end
      end
    end
  end

  local untracked = run("git ls-files --others --exclude-standard") or ""
  for path in untracked:gmatch("[^\n]+") do
    if not seen[path] then
      changes[#changes + 1] =
        { path = path, status = "?", adds = 0, dels = 0, untracked = true }
    end
  end

  table.sort(changes, function(a, b)
    return a.path < b.path
  end)
  return changes
end

-- Returns array of { sha, subject, when } or nil, err.
local function git_log()
  local out, err =
    run("git log --no-color -n 200 --pretty=format:'%h%x09%s%x09%ar'")
  if not out then
    return nil, err
  end
  local log = {}
  for line in out:gmatch("[^\n]+") do
    local sha, subject, when = line:match("^(%S+)\t(.-)\t(.-)$")
    if sha then
      log[#log + 1] = { sha = sha, subject = subject, when = when }
    end
  end
  return log
end

-- Files changed by one commit; same shape as git_changes, plus .commit.
local function git_commit_changes(sha)
  local changes, seen = {}, {}
  local ns, err =
    run("git diff-tree -r --root --no-commit-id --name-status " .. sha)
  if not ns then
    return nil, err
  end
  for line in ns:gmatch("[^\n]+") do
    local status, rest = line:match("^(%S+)\t(.+)$")
    if status then
      local path = rest:match("\t(.+)$") or rest
      seen[path] = #changes + 1
      changes[#changes + 1] = {
        path = path,
        status = status:sub(1, 1),
        adds = 0,
        dels = 0,
        commit = sha,
      }
    end
  end
  local numstat =
    run("git diff-tree -r --root --no-commit-id --numstat " .. sha) or ""
  for line in numstat:gmatch("[^\n]+") do
    local adds, dels, path = line:match("^(%S+)\t(%S+)\t(.+)$")
    if path then
      local idx = seen[path]
      if idx then
        if adds == "-" then
          changes[idx].binary = true
        else
          changes[idx].adds = tonumber(adds) or 0
          changes[idx].dels = tonumber(dels) or 0
        end
      end
    end
  end
  table.sort(changes, function(a, b)
    return a.path < b.path
  end)
  return changes
end

-- Parses unified diff text into { kind, text, old_ln, new_ln } lines.
-- kind: "hunk" | "ctx" | "add" | "del". Meta lines are dropped.
local function parse_diff(raw)
  local out = {}
  local old_ln, new_ln = 0, 0
  local in_hunk = false
  for line in raw:gmatch("[^\n]*\n?") do
    line = line:gsub("\n$", "")
    if line == "" and #out == 0 then
      continue
    end
    local os_, ns_ = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
    if os_ then
      old_ln, new_ln = tonumber(os_), tonumber(ns_)
      in_hunk = true
      out[#out + 1] = { kind = "hunk", text = line }
    elseif in_hunk then
      local c = line:sub(1, 1)
      if c == "+" then
        out[#out + 1] = { kind = "add", text = line:sub(2), new_ln = new_ln }
        new_ln = new_ln + 1
      elseif c == "-" then
        out[#out + 1] = { kind = "del", text = line:sub(2), old_ln = old_ln }
        old_ln = old_ln + 1
      elseif c == " " then
        out[#out + 1] = {
          kind = "ctx",
          text = line:sub(2),
          old_ln = old_ln,
          new_ln = new_ln,
        }
        old_ln = old_ln + 1
        new_ln = new_ln + 1
      end
      -- "\ No newline at end of file" and new "diff --git" headers fall through
      if line:sub(1, 10) == "diff --git" then
        in_hunk = false
      end
    end
  end
  return out
end

local function get_diff(change)
  local ctx = full_file and "--unified=1000000 " or ""
  local cmd
  if change.commit then
    cmd = "git show --no-color --format= " .. ctx
      .. change.commit
      .. " -- "
      .. sh_quote(change.path)
  elseif change.untracked then
    cmd = "git diff --no-color --no-index " .. ctx .. "-- /dev/null " .. sh_quote(change.path)
  else
    cmd = "git diff --no-color " .. ctx .. "HEAD -- " .. sh_quote(change.path)
  end
  local raw, err = run(cmd)
  if not raw then
    return nil, err
  end
  return parse_diff(raw)
end

--- syntax highlighting -----------------------------------------------------

-- Highlights the code text of every non-hunk diff line in a single call.
-- Returns map: dline idx -> spans ({ {text, style}, ... }), or nil.
local function highlight_dlines(path, dlines)
  local lang = path:match("%.([%w_]+)$") or path:match("([^/]+)$") or ""
  local code, idxs = {}, {}
  for i, dl in ipairs(dlines) do
    if dl.kind ~= "hunk" then
      code[#code + 1] = dl.text
      idxs[#idxs + 1] = i
    end
  end
  if #code == 0 then
    return nil
  end
  local ok, styled = pcall(
    maki.ui.highlight,
    table.concat(code, "\n"),
    lang,
    { independent = true }
  )
  if not ok or type(styled) ~= "table" or #styled ~= #code then
    return nil
  end
  local hl = {}
  for j, spans in ipairs(styled) do
    hl[idxs[j]] = spans
  end
  return hl
end

--- comments ----------------------------------------------------------------

local function covers(c, dl)
  if dl.kind == "del" then
    return c.old_start and dl.old_ln and dl.old_ln >= c.old_start and dl.old_ln <= c.old_end
  end
  return c.new_start and dl.new_ln and dl.new_ln >= c.new_start and dl.new_ln <= c.new_end
end

local function comment_at(change, dl)
  for i, c in ipairs(comments) do
    if c.file == change.path and c.commit == change.commit and covers(c, dl) then
      return c, i
    end
  end
  return nil
end

-- Builds a comment record from a contiguous range of parsed diff lines.
local function make_comment(change, dlines, from, to, text)
  local c = { file = change.path, commit = change.commit, text = text }
  for i = from, to do
    local dl = dlines[i]
    if dl.new_ln then
      c.new_start = math.min(c.new_start or dl.new_ln, dl.new_ln)
      c.new_end = math.max(c.new_end or dl.new_ln, dl.new_ln)
    end
    if dl.old_ln then
      c.old_start = math.min(c.old_start or dl.old_ln, dl.old_ln)
      c.old_end = math.max(c.old_end or dl.old_ln, dl.old_ln)
    end
  end
  c.anchor = dlines[to].kind == "del" and "old" or "new"

  -- Snapshot the hunk context so the prompt survives later refreshes.
  local snippet = {}
  for i = from - 1, 1, -1 do
    if dlines[i].kind == "hunk" then
      snippet[1] = dlines[i].text
      break
    end
  end
  local lo, hi = math.max(from - 2, 1), math.min(to + 2, #dlines)
  for i = lo, hi do
    local dl = dlines[i]
    if dl.kind ~= "hunk" then
      local prefix = dl.kind == "add" and "+" or dl.kind == "del" and "-" or " "
      local marked = (i >= from and i <= to) and "  <<< comment applies here" or ""
      if #snippet < 80 then
        snippet[#snippet + 1] = prefix .. dl.text .. marked
      end
    end
  end
  c.snippet = table.concat(snippet, "\n")
  return c
end

local function line_range_label(c)
  if c.anchor == "old" then
    if c.old_start == c.old_end then
      return "removed line " .. c.old_start
    end
    return "removed lines " .. c.old_start .. "-" .. c.old_end
  end
  if c.new_start == c.new_end then
    return "line " .. c.new_start
  end
  return "lines " .. c.new_start .. "-" .. c.new_end
end

--- submit ------------------------------------------------------------------

local function build_prompt()
  local by_file, order = {}, {}
  for _, c in ipairs(comments) do
    if not by_file[c.file] then
      by_file[c.file] = {}
      order[#order + 1] = c.file
    end
    table.insert(by_file[c.file], c)
  end

  local p = {
    "I reviewed changes in this repository and left review comments. Comments refer either",
    "to the uncommitted diff vs HEAD, or to a specific commit's diff (noted as `commit <sha>`).",
    "Address every comment: apply the requested fix directly on the current working tree.",
    "If a comment is a question, answer it and apply any change the answer implies.",
    "Line numbers refer to the file content on the commented side of the diff",
    "(\"removed\" lines refer to the pre-change file).",
    "",
  }
  for _, file in ipairs(order) do
    p[#p + 1] = "## " .. file
    for i, c in ipairs(by_file[file]) do
      p[#p + 1] = ""
      local where = line_range_label(c)
      if c.commit then
        where = where .. ", commit " .. c.commit
      end
      p[#p + 1] = "### Comment " .. i .. " (" .. where .. ")"
      for cline in (c.text .. "\n"):gmatch("(.-)\n") do
        p[#p + 1] = "> " .. cline
      end
      p[#p + 1] = ""
      p[#p + 1] = "```diff"
      p[#p + 1] = c.snippet
      p[#p + 1] = "```"
    end
    p[#p + 1] = ""
  end
  return table.concat(p, "\n")
end

local function submit(state)
  if #comments == 0 then
    maki.ui.flash("No review comments yet — press c on a diff line first")
    return false
  end
  local n = #comments
  local prompt = build_prompt()
  local _, err = maki.session.new({ prompt = prompt, focus = true })
  if err then
    maki.ui.flash("Failed to start session: " .. err)
    return false
  end
  comments = {}
  if state then
    for _, w in ipairs({ "fwin", "cwin", "mwin", "rwin", "swin" }) do
      if state[w] then
        state[w]:close()
      end
    end
  end
  maki.ui.flash("Sent " .. n .. " comment(s) to a new session")
  return true
end

--- span helpers ------------------------------------------------------------

local function wrap(text, width)
  local lines = {}
  for raw in (text .. "\n"):gmatch("(.-)\n") do
    if raw == "" then
      lines[#lines + 1] = ""
    end
    while #raw > 0 do
      if #raw <= width then
        lines[#lines + 1] = raw
        break
      end
      local cut = width
      for i = width, math.max(width - 20, 1), -1 do
        if raw:sub(i, i) == " " then
          cut = i
          break
        end
      end
      lines[#lines + 1] = raw:sub(1, cut)
      raw = raw:sub(cut + 1):gsub("^%s+", "")
    end
  end
  return lines
end

local function display_len(s)
  local ok, n = pcall(utf8.len, s)
  if ok and n then
    return n
  end
  return #s
end

local function sanitize_utf8(s)
  if not s or s == "" then return s end
  local ok = pcall(utf8.len, s)
  if ok then return s end
  -- Extract valid UTF-8 characters, skip invalid bytes
  local out, i, n = {}, 1, #s
  while i <= n do
    local ok, next = pcall(utf8.offset, s, 1, i)
    if ok then
      out[#out + 1] = s:sub(i, next - 1)
      i = next
    else
      i = i + 1
    end
  end
  return table.concat(out)
end

local function spans_len(spans)
  local n = 0
  for _, sp in ipairs(spans) do
    n = n + display_len(sp[1])
  end
  return n
end

-- Pads `spans` with spaces (styled `style`) up to `width` columns.
local function pad_spans(spans, width, style)
  local n = spans_len(spans)
  if n < width then
    spans[#spans + 1] = { string.rep(" ", width - n), style or "" }
  end
  return spans
end

-- Restyles every span with `style`.
local function restyle(spans, style)
  local out = {}
  for _, sp in ipairs(spans) do
    out[#out + 1] = { sp[1], style }
  end
  return out
end

-- Returns copies of `spans` with `bg` added to each span's style,
-- keeping syntax foreground colors.
local function with_bg(spans, bg)
  local out = {}
  for _, sp in ipairs(spans) do
    local s = sp[2]
    local ns = { bg = bg }
    if type(s) == "table" then
      ns.fg = s.fg
      ns.bold = s.bold
      ns.italic = s.italic
      ns.underline = s.underline
    end
    out[#out + 1] = { sp[1], ns }
  end
  return out
end

--- rendering ---------------------------------------------------------------

local STATUS_STYLE =
  { M = "warning", A = "diff_new", D = "diff_old", R = "accent", ["?"] = "diff_new" }

-- Shortens a path from the left to fit `max` columns.
local function fit_path(path, max)
  if display_len(path) <= max then
    return path
  end
  return "…" .. path:sub(-(max - 1))
end

-- Builds a directory tree from a flat change list. Single-child directory
-- chains are compressed into one node ("a/b/c").
local function build_tree(changes)
  local root = { dirs = {}, dorder = {}, files = {} }
  for i, ch in ipairs(changes) do
    local parts = {}
    for s in ch.path:gmatch("[^/]+") do
      parts[#parts + 1] = s
    end
    local node, prefix = root, ""
    for j = 1, #parts - 1 do
      prefix = prefix == "" and parts[j] or (prefix .. "/" .. parts[j])
      local d = node.dirs[parts[j]]
      if not d then
        d = { name = parts[j], path = prefix, dirs = {}, dorder = {}, files = {} }
        node.dirs[parts[j]] = d
        node.dorder[#node.dorder + 1] = d
      end
      node = d
    end
    node.files[#node.files + 1] = { name = parts[#parts], idx = i }
  end
  local function compress(node)
    for _, d in ipairs(node.dorder) do
      while #d.dorder == 1 and #d.files == 0 do
        local child = d.dorder[1]
        d.name = d.name .. "/" .. child.name
        d.path = child.path
        d.dirs = child.dirs
        d.dorder = child.dorder
        d.files = child.files
      end
      compress(d)
    end
  end
  compress(root)
  return root
end

-- Renders a change list as a collapsible directory tree into `buf`.
-- row_map values: number (index into `changes`) or { dir = path }.
local function render_change_list(state, buf, changes, cursor, active, empty_msg, collapsed)
  local width = math.max(state.lwidth, 20)
  local lines, row_map = {}, {}
  if #changes == 0 then
    lines[#lines + 1] = { { empty_msg, "dim" } }
  end

  local function push(spans, val)
    lines[#lines + 1] = spans
    row_map[#lines] = val
    if #lines == cursor then
      if active and not state.centry then
        lines[#lines] = pad_spans(restyle(spans, "selected"), width, "selected")
      else
        -- Inactive panel: keep the selection visible, without the bar.
        local marked = restyle(spans, "active")
        marked[1] = { "▎" .. spans[1][1]:sub(2), "accent" }
        lines[#lines] = marked
      end
    end
  end

  -- Total files and review comments under a directory node.
  local function dir_stats(d)
    local nfiles, ncoms = #d.files, 0
    for _, f in ipairs(d.files) do
      ncoms = ncoms + comment_count(changes[f.idx])
    end
    for _, sub in ipairs(d.dorder) do
      local sf, sc = dir_stats(sub)
      nfiles = nfiles + sf
      ncoms = ncoms + sc
    end
    return nfiles, ncoms
  end

  local function emit_file(f, depth)
    local ch = changes[f.idx]
    local n = comment_count(ch)
    local right
    if ch.binary then
      right = "bin"
    elseif ch.untracked then
      right = ch.adds > 0 and ("+" .. ch.adds) or "new"
    else
      right = "+" .. ch.adds .. " -" .. ch.dels
    end
    local badge = n > 0 and (COMMENT_MARK .. n .. " ") or ""
    local prefix = " " .. string.rep("  ", depth) .. ch.status .. " "
    local avail = width
      - display_len(prefix)
      - display_len(right)
      - display_len(badge)
      - 2
    local spans = {
      { prefix, STATUS_STYLE[ch.status] or "item" },
      { fit_path(f.name, math.max(avail, 8)), "item" },
    }
    pad_spans(spans, width - display_len(right) - display_len(badge) - 1)
    if badge ~= "" then
      spans[#spans + 1] = { badge, "warning" }
    end
    spans[#spans + 1] = {
      right,
      ch.untracked and "diff_new" or (ch.binary and "dim" or "accent"),
    }
    push(spans, f.idx)
  end

  local walk
  local function emit_dir(d, depth)
    local isc = collapsed[d.path]
    local nfiles, ncoms = dir_stats(d)
    local right = isc and (nfiles .. " files") or ""
    local badge = ncoms > 0 and (COMMENT_MARK .. ncoms .. " ") or ""
    local prefix = " " .. string.rep("  ", depth) .. (isc and "▸ " or "▾ ")
    local avail = width
      - display_len(prefix)
      - display_len(right)
      - display_len(badge)
      - 2
    local spans = {
      { prefix, "accent" },
      { fit_path(d.name .. "/", math.max(avail, 8)), "item" },
    }
    pad_spans(spans, width - display_len(right) - display_len(badge) - 1)
    if badge ~= "" then
      spans[#spans + 1] = { badge, "warning" }
    end
    if right ~= "" then
      spans[#spans + 1] = { right, "dim" }
    end
    push(spans, { dir = d.path })
    if not isc then
      walk(d, depth + 1)
    end
  end

  walk = function(node, depth)
    for _, d in ipairs(node.dorder) do
      emit_dir(d, depth)
    end
    for _, f in ipairs(node.files) do
      emit_file(f, depth)
    end
  end
  walk(build_tree(changes), 0)

  buf:set_lines(lines)
  return row_map
end

-- Renders the commit list into cbuf. Returns row_map (row -> commit idx).
local function render_commit_list(state)
  local width = math.max(state.lwidth, 20)
  local active = state.pane == "commits" and not state.centry
  local lines, row_map = {}, {}
  if #state.commits == 0 then
    lines[#lines + 1] = { { "  No commits.", "dim" } }
  end
  for i, cm in ipairs(state.commits) do
    local sha = sanitize_utf8(cm.sha or "")
    local when = sanitize_utf8(cm.when or ""):gsub(" ago$", "")
    local subject = sanitize_utf8(cm.subject or "")
    local avail = width - #sha - display_len(when) - 4
    if display_len(subject) > avail then
      local cut = math.max(avail - 1, 1)
      -- Ensure `cut` lands on a UTF-8 boundary
      while cut > 0 do
        local ok, pos = pcall(utf8.offset, subject, 0, cut + 1)
        if ok and pos == cut + 1 then break end
        cut = cut - 1
      end
      subject = subject:sub(1, cut) .. "…"
    end
    local spans = {
      { " " .. sha .. " ", "accent" },
      { subject, "item" },
    }
    pad_spans(spans, width - display_len(when) - 1)
    spans[#spans + 1] = { when, "dim" }
    lines[#lines + 1] = spans
    row_map[#lines] = i
    if #lines == state.ccursor then
      if active then
        lines[#lines] = pad_spans(restyle(spans, "selected"), width, "selected")
      else
        local marked = restyle(spans, "active")
        marked[1] = { "▎" .. sha .. " ", "accent" }
        lines[#lines] = marked
      end
    end
  end
  state.cbuf:set_lines(lines)
  return row_map
end

-- Renders all review comments into mbuf. Returns row_map (row -> comment idx).
local function render_comment_list(state)
  local width = math.max(state.lwidth, 20)
  local active = state.pane == "comments" and not state.centry
  local lines, row_map = {}, {}
  if #comments == 0 then
    lines[#lines + 1] = { { "  No comments yet.", "dim" } }
    lines[#lines + 1] = { { "  Press c on a diff line.", "dim" } }
  end
  for i, c in ipairs(comments) do
    local ln = c.anchor == "old" and c.old_start or c.new_start
    local name = c.file:match("([^/]+)$") or c.file
    local loc = name .. ":" .. tostring(ln or "?")
    if c.commit then
      loc = loc .. " @" .. c.commit
    end
    loc = fit_path(loc, math.max(width - 4, 8))
    local spans = {
      { " " .. COMMENT_MARK, "warning" },
      { loc, "item" },
    }
    local avail = width - 3 - display_len(loc) - 2
    if avail > 4 then
      local preview = c.text:gsub("%s+", " ")
      if display_len(preview) > avail then
        preview = preview:sub(1, math.max(avail - 1, 1)) .. "…"
      end
      spans[#spans + 1] = { " " .. preview, "dim" }
    end
    lines[#lines + 1] = spans
    row_map[#lines] = i
    if #lines == state.mcursor then
      if active then
        lines[#lines] = pad_spans(restyle(spans, "selected"), width, "selected")
      else
        local marked = restyle(spans, "active")
        marked[1] = { "▎" .. COMMENT_MARK, "warning" }
        lines[#lines] = marked
      end
    end
  end
  state.mbuf:set_lines(lines)
  return row_map
end

-- Renders the diff of state.change into rbuf.
-- Appends the inline comment editor to `lines`; returns the editor's
-- last row.
local function push_editor(state, lines, width)
  local editor_row
  lines[#lines + 1] = {
    { "    ┌ ", "accent" },
    { "Comment (" .. state.centry.label .. ")", "accent" },
    { "  Enter: save  Esc: cancel", "dim" },
  }
  local r = state.centry.input:render("    │ ", 6, math.max(width - 8, 20))
  for _, l in ipairs(r.lines) do
    lines[#lines + 1] = l
    editor_row = #lines
  end
  lines[#lines + 1] = { { "    └", "accent" } }
  return editor_row
end

-- Appends comment `c` as a full-width tinted block.
local function push_comment(lines, c, width, tint)
  local cbg = tint.com
  local bar = { fg = COM_TINT[1], bg = cbg, bold = true }
  local txt = cbg and { bg = cbg, bold = true } or "warning"
  local hdr = { { "    ┏ ", bar }, { "● Comment", bar } }
  if cbg then
    pad_spans(hdr, width, { bg = cbg })
  end
  lines[#lines + 1] = hdr
  for _, cl in ipairs(wrap(c.text, math.max(width - 10, 20))) do
    local cspans = { { COMMENT_BAR, bar }, { cl, txt } }
    if cbg then
      pad_spans(cspans, width, { bg = cbg })
    end
    lines[#lines + 1] = cspans
  end
end

-- True when comment `c` ends on dline `i` (the next line is not covered).
local function comment_ends_at(dlines, c, i)
  local nxt = dlines[i + 1]
  return not (nxt and nxt.kind ~= "hunk" and covers(c, nxt))
end

-- Cuts `spans` to at most `max` display columns; tabs become 4 spaces.
local function truncate_spans(spans, max)
  local out, used = {}, 0
  for _, sp in ipairs(spans) do
    if used >= max then
      break
    end
    local t = sp[1]:gsub("\t", "    ")
    local n = display_len(t)
    if used + n > max then
      t = maki.ui.truncate_text(t, max - used).head
      n = display_len(t)
    end
    out[#out + 1] = { t, sp[2] }
    used = used + n
  end
  return out
end

-- Gutter + code spans for dline `i`. `side` picks the line number shown
-- ("old" | "new"); nil means unified (old for deletions, new otherwise).
local function code_spans(state, i, side)
  local dl = state.dlines[i]
  local c = comment_at(state.change, dl)
  local ln
  if side == "old" then
    ln = dl.old_ln
  elseif side == "new" then
    ln = dl.new_ln
  else
    ln = dl.kind == "del" and dl.old_ln or dl.new_ln
  end
  local sign = dl.kind == "add" and "+" or dl.kind == "del" and "-" or " "
  local base = dl.kind == "add" and "diff_new"
    or dl.kind == "del" and "diff_old"
    or "item"
  local text_spans
  if state.hl and state.hl[i] and #state.hl[i] > 0 then
    text_spans = state.hl[i]
  else
    text_spans = { { dl.text, base } }
  end
  local spans = {
    { c and COMMENT_MARK or "  ", "warning" },
    { string.format("%4d ", ln or 0), "dim" },
    { sign .. " ", base },
  }
  return spans, text_spans
end

local function line_bg(dl, selected, tint)
  if selected then
    return tint.sel
  elseif dl.kind == "add" then
    return tint.add
  elseif dl.kind == "del" then
    return tint.del
  end
end

-- One half of a split row, exactly `hw` columns wide.
local function side_cell(state, i, side, hw, tint, vfrom, vto)
  if not i then
    return { { string.rep(" ", hw), "" } }
  end
  local spans, text_spans = code_spans(state, i, side)
  for _, sp in ipairs(truncate_spans(text_spans, math.max(hw - 9, 1))) do
    spans[#spans + 1] = { sp[1], sp[2] }
  end
  local bg = line_bg(state.dlines[i], vfrom and i >= vfrom and i <= vto, tint)
  if bg then
    spans = with_bg(spans, bg)
    pad_spans(spans, hw, { bg = bg })
  else
    pad_spans(spans, hw, "")
  end
  return spans
end

-- Pairs dlines into split rows: { hunk = i } or { old = i?, new = i? }.
local function split_rows(dlines)
  local rows, i = {}, 1
  while i <= #dlines do
    local dl = dlines[i]
    if dl.kind == "hunk" then
      rows[#rows + 1] = { hunk = i }
      i = i + 1
    elseif dl.kind == "ctx" then
      rows[#rows + 1] = { old = i, new = i }
      i = i + 1
    else
      local dels, adds = {}, {}
      while dlines[i] and dlines[i].kind == "del" do
        dels[#dels + 1] = i
        i = i + 1
      end
      while dlines[i] and dlines[i].kind == "add" do
        adds[#adds + 1] = i
        i = i + 1
      end
      for k = 1, math.max(#dels, #adds) do
        rows[#rows + 1] = { old = dels[k], new = adds[k] }
      end
    end
  end
  return rows
end

-- Side-by-side diff: old code left, new code right.
local function render_split(state, lines, row_map, width, tint, vfrom, vto)
  local editor_row
  local active = state.pane == "diff"
  local dlines, ch = state.dlines, state.change
  local hw = math.max(math.floor((width - 1) / 2), 12)
  state.drow_sides = {}
  for _, row in ipairs(split_rows(dlines)) do
    if row.hunk then
      local spans = { { " " .. dlines[row.hunk].text, "accent" } }
      lines[#lines + 1] = spans
      row_map[#lines] = row.hunk
      if active and #lines == state.dcursor and not state.centry then
        lines[#lines] = pad_spans(restyle(spans, "selected"), width, "selected")
      end
      continue
    end
    local spans = side_cell(state, row.old, "old", hw, tint, vfrom, vto)
    spans[#spans + 1] = { "│", "dim" }
    for _, sp in ipairs(side_cell(state, row.new, "new", hw, tint, vfrom, vto)) do
      spans[#spans + 1] = sp
    end
    lines[#lines + 1] = spans
    row_map[#lines] = row.new or row.old
    state.drow_sides[#lines] = row
    if active and #lines == state.dcursor and not state.centry then
      lines[#lines] = pad_spans(restyle(spans, "selected"), width, "selected")
    end

    local idxs = row.old == row.new and { row.old } or { row.old, row.new }
    if state.centry then
      for _, i in pairs(idxs) do
        if state.centry.at == i then
          editor_row = push_editor(state, lines, width)
          break
        end
      end
    end
    local shown = {}
    for _, i in pairs(idxs) do
      local c = comment_at(ch, dlines[i])
      if c and not shown[c] and comment_ends_at(dlines, c, i) then
        shown[c] = true
        push_comment(lines, c, width, tint)
      end
    end
  end
  return editor_row
end

-- Returns row_map (row -> dline idx), editor_row.
local function render_diff(state)
  local width = math.max(state.rwidth, 20)
  local lines, row_map = {}, {}
  local ch = state.change
  local tint = get_tints()
  state.drow_sides = nil

  if not ch then
    lines[#lines + 1] = { { "", "" } }
    lines[#lines + 1] = { { "  Select a file on the left.", "dim" } }
    state.rbuf:set_lines(lines)
    return row_map, nil
  end

  local dlines = state.dlines
  if not dlines then
    lines[#lines + 1] = { { "", "" } }
    lines[#lines + 1] =
      { { "  " .. (state.diff_err or "No diff to show."), "dim" } }
    state.rbuf:set_lines(lines)
    return row_map, nil
  end

  local vfrom, vto
  if state.vstart then
    vfrom = math.min(state.vstart, state.vcur)
    vto = math.max(state.vstart, state.vcur)
  end

  if split_view then
    local editor_row = render_split(state, lines, row_map, width, tint, vfrom, vto)
    state.rbuf:set_lines(lines)
    return row_map, editor_row
  end

  local editor_row = nil
  local active = state.pane == "diff"

  for i, dl in ipairs(dlines) do
    if dl.kind == "hunk" then
      local spans = { { " " .. dl.text, "accent" } }
      lines[#lines + 1] = spans
      row_map[#lines] = i
      if active and #lines == state.dcursor and not state.centry then
        lines[#lines] = pad_spans(restyle(spans, "selected"), width, "selected")
      end
      continue
    end

    local spans, text_spans = code_spans(state, i, nil)
    for _, sp in ipairs(text_spans) do
      spans[#spans + 1] = { sp[1], sp[2] }
    end

    -- Full-row background tint by line kind / selection.
    local bg = line_bg(dl, vfrom and i >= vfrom and i <= vto, tint)
    if bg then
      spans = with_bg(spans, bg)
      pad_spans(spans, width, { bg = bg })
    end

    lines[#lines + 1] = spans
    row_map[#lines] = i
    if active and #lines == state.dcursor and not state.centry then
      lines[#lines] = pad_spans(restyle(spans, "selected"), width, "selected")
    end

    -- Inline comment editor, right below the anchor line.
    if state.centry and state.centry.at == i then
      editor_row = push_editor(state, lines, width)
    end

    -- Show the comment right below the last diff line it covers, in a
    -- full-width tinted block so it stands out from the code.
    local c = comment_at(ch, dl)
    if c and comment_ends_at(dlines, c, i) then
      push_comment(lines, c, width, tint)
    end
  end

  state.rbuf:set_lines(lines)
  return row_map, editor_row
end

-- Right pane: summary of the commit under the cursor (commit list view).
local function render_commit_info(state)
  local lines = {}
  local cm = state.sel_commit
  if not cm then
    lines[#lines + 1] = { { "", "" } }
    lines[#lines + 1] = { { "  Select a commit on the left.", "dim" } }
  else
    local raw = state.cache["info:" .. cm.sha] or ""
    lines[#lines + 1] = { { "", "" } }
    for l in (raw .. "\n"):gmatch("(.-)\n") do
      local style = "item"
      if l:match("^commit ") then
        style = "accent"
      elseif l:match("^%u[%w-]*:") then
        style = "dim"
      end
      lines[#lines + 1] = { { " " .. l, style } }
    end
    lines[#lines + 1] = { { "  Enter: browse the files of this commit", "dim" } }
  end
  state.rbuf:set_lines(lines)
end

-- Right pane: full text + snippet of the comment under the cursor.
local function render_comment_detail(state)
  local width = math.max(state.rwidth, 20)
  local tint = get_tints()
  local lines = {}
  local c = comments[state.mrow_map and state.mrow_map[state.mcursor]]
  if not c then
    lines[#lines + 1] = { { "", "" } }
    lines[#lines + 1] = { { "  No comment selected.", "dim" } }
    state.rbuf:set_lines(lines)
    return
  end
  local where = line_range_label(c)
  if c.commit then
    where = where .. "  ·  commit " .. c.commit
  end
  lines[#lines + 1] = { { "", "" } }
  lines[#lines + 1] = { { " " .. c.file, "accent" } }
  lines[#lines + 1] = { { " " .. where, "dim" } }
  lines[#lines + 1] = { { "", "" } }
  local cbg = tint.com
  local bar = { fg = COM_TINT[1], bg = cbg, bold = true }
  local txt = cbg and { bg = cbg, bold = true } or "warning"
  for _, cl in ipairs(wrap(c.text, math.max(width - 8, 20))) do
    local spans = { { " ┃ ", bar }, { cl, txt } }
    if cbg then
      pad_spans(spans, width, { bg = cbg })
    end
    lines[#lines + 1] = spans
  end
  lines[#lines + 1] = { { "", "" } }
  for sl in (c.snippet .. "\n"):gmatch("(.-)\n") do
    local ch1 = sl:sub(1, 1)
    local style = "item"
    if sl:match("^@@") then
      style = "accent"
    elseif ch1 == "+" then
      style = "diff_new"
    elseif ch1 == "-" then
      style = "diff_old"
    end
    lines[#lines + 1] = { { " " .. sl, style } }
  end
  state.rbuf:set_lines(lines)
end

-- Renders a left panel and clamps its cursor to a mapped row, re-rendering
-- once when the cursor had to move (so the selection bar lands right).
local function render_clamped(state, render, cur_key, buf)
  local map = render(state)
  if not map[state[cur_key]] then
    state[cur_key] = 1
    for r = 1, buf:len() do
      if map[r] then
        state[cur_key] = r
        break
      end
    end
    map = render(state)
  end
  return map
end

-- Dims every row of an inactive panel except the cursor row, so the
-- focused panel stands out.
local function dim_panel(buf, keep_row)
  local lines = buf:get_lines()
  for r, spans in ipairs(lines) do
    if r ~= keep_row then
      lines[r] = restyle(spans, "dim")
    end
  end
  buf:set_lines(lines)
end

local function redraw(state)
  -- Left column: files, commits, comments (stacked).
  state.frow_map = render_clamped(state, function(s)
    return render_change_list(
      s,
      s.fbuf,
      s.wchanges,
      s.fcursor,
      s.pane == "files",
      NO_CHANGES,
      s.fcollapsed
    )
  end, "fcursor", state.fbuf)

  local crender = render_commit_list
  if state.commit then
    crender = function(s)
      return render_change_list(
        s,
        s.cbuf,
        s.commit_changes or {},
        s.ccursor,
        s.pane == "commits",
        "  No files in commit.",
        s.ccollapsed
      )
    end
  end
  state.crow_map = render_clamped(state, crender, "ccursor", state.cbuf)

  state.mrow_map =
    render_clamped(state, render_comment_list, "mcursor", state.mbuf)

  -- Right pane: driven by the panel that last had focus (state.src).
  local drow_map, editor_row = {}, nil
  if state.src == "commits" and not state.commit then
    render_commit_info(state)
  elseif state.src == "comments" then
    render_comment_detail(state)
  else
    drow_map, editor_row = render_diff(state)
  end
  state.drow_map = drow_map

  if state.change and not state.drow_map[state.dcursor] then
    for r = state.dcursor, 1, -1 do
      if drow_map[r] then
        state.dcursor = r
        break
      end
    end
    if not drow_map[state.dcursor] then
      state.dcursor = 1
    end
  end

  local diff_active = state.pane == "diff" or state.centry ~= nil

  if state.pane ~= "files" or state.centry then
    dim_panel(state.fbuf, state.fcursor)
  end
  if state.pane ~= "commits" or state.centry then
    dim_panel(state.cbuf, state.ccursor)
  end
  if state.pane ~= "comments" or state.centry then
    dim_panel(state.mbuf, state.mcursor)
  end

  local function mark(title, active, keep_case)
    if not active then
      return title
    end
    return " ▶" .. (keep_case and title or title:upper()) .. "◀ "
  end

  local function panel_cfg(win, title, active, footer)
    win:set_config({
      title = mark(title, active),
      border = active and "double" or "single",
      footer = active and footer or { { "Tab", "focus" } },
    })
  end

  panel_cfg(
    state.fwin,
    " Files (" .. #state.wchanges .. ") ",
    state.pane == "files" and not state.centry,
    {
      { "Enter", "diff" },
      { "s", "submit " .. #comments },
      { "Esc", "close" },
    }
  )

  local ctitle, cfooter
  if state.commit then
    ctitle = " " .. state.commit.sha .. " (" .. #(state.commit_changes or {}) .. ") "
    cfooter = { { "Enter", "diff" }, { "Esc", "back" } }
  else
    ctitle = " Commits "
    cfooter = { { "Enter", "open" }, { "Esc", "close" } }
  end
  panel_cfg(
    state.cwin,
    ctitle,
    state.pane == "commits" and not state.centry,
    cfooter
  )

  panel_cfg(
    state.mwin,
    " Comments (" .. #comments .. ") ",
    state.pane == "comments" and not state.centry,
    {
      { "d", "delete" },
      { "s", "submit " .. #comments },
    }
  )

  local rtitle = " Diff "
  if state.src == "commits" and not state.commit then
    rtitle = state.sel_commit and (" Commit " .. state.sel_commit.sha .. " ")
      or " Commit "
  elseif state.src == "comments" then
    rtitle = " Comment "
  elseif state.change then
    rtitle = " "
      .. fit_path(state.change.path, math.max(state.rwidth - 14, 12))
      .. "  +"
      .. state.change.adds
      .. " -"
      .. state.change.dels
      .. " "
  end
  state.rwin:set_config({
    title = mark(rtitle, diff_active, true),
    border = diff_active and "double" or "single",
    footer = state.centry
        and { { "Enter", "save" }, { "Esc", "cancel" } }
      or (diff_active and {
          { "Tab", "next change" },
        { "n/p", "file" },
        { "t", split_view and "unified" or "split" },
        { "f", full_file and "hunks" or "full file" },
        { "c", "comment" },
        { "v", state.vstart and "cancel select" or "select" },
        { "d", "delete" },
        { "s", "submit " .. #comments },
        { "Esc", "back" },
      } or { { "Enter", "diff" } }),
  })

  local where = state.centry and "editing comment"
    or (state.pane == "diff" and "diff") or state.pane
  local hints = { { "pane", where } }
  if state.commit then
    hints[#hints + 1] = { "commit", state.commit.sha }
  end
  if state.change then
    hints[#hints + 1] = { "file", state.change.path }
    hints[#hints + 1] = { "view", split_view and "split" or "unified" }
    hints[#hints + 1] = { "show", full_file and "full file" or "hunks" }
  end
  if state.vstart then
    hints[#hints + 1] = { "v", "selecting" }
  end
  hints[#hints + 1] = { tostring(#comments), #comments == 1 and "comment" or "comments" }
  hints[#hints + 1] = { "?", "help" }
  local bar = { { " REVIEW ", { bold = true, reversed = true } } }
  for _, h in ipairs(hints) do
    bar[#bar + 1] = { "  " .. h[1] .. " ", "accent" }
    bar[#bar + 1] = { h[2], "dim" }
  end
  state.sbuf:set_lines({ bar })

  state.fwin:set_cursor(state.fcursor)
  state.cwin:set_cursor(state.ccursor)
  state.mwin:set_cursor(state.mcursor)
  state.rwin:set_cursor(editor_row or state.dcursor)
end

--- preview loading ---------------------------------------------------------

-- Loads the right-pane content for the selection in the source panel.
local function load_preview(state)
  state.change = nil
  state.dlines = nil
  state.hl = nil
  state.diff_err = nil
  state.vstart = nil
  state.centry = nil
  state.dcursor = 1
  state.sel_commit = nil

  if state.src == "comments" then
    return
  end
  if state.src == "commits" and not state.commit then
    local cm = state.commits[state.crow_map and state.crow_map[state.ccursor]]
    state.sel_commit = cm
    if cm and not state.cache["info:" .. cm.sha] then
      state.cache["info:" .. cm.sha] =
        run("git show --no-color --format=medium --stat " .. cm.sha) or ""
    end
    return
  end

  local ch
  if state.src == "commits" then
    ch = (state.commit_changes or {})[state.crow_map and state.crow_map[state.ccursor]]
  else
    ch = state.wchanges[state.frow_map and state.frow_map[state.fcursor]]
  end
  state.change = ch
  if not ch then
    return
  end
  if ch.binary then
    state.diff_err = "Binary file — nothing to show."
    return
  end

  local key = (full_file and "full:" or "") .. (ch.commit or "") .. ":" .. ch.path
  local cached = state.cache[key]
  if not cached then
    local dlines, err = get_diff(ch)
    if not dlines then
      state.diff_err = "diff failed: " .. tostring(err)
      return
    end
    cached = { dlines = dlines, hl = highlight_dlines(ch.path, dlines) }
    state.cache[key] = cached
    if ch.untracked then
      local n = 0
      for _, dl in ipairs(dlines) do
        if dl.kind == "add" then
          n = n + 1
        end
      end
      ch.adds = n
    end
  end
  state.dlines = cached.dlines
  state.hl = cached.hl

  -- Cursor starts on the first changed (add/del) line.
  state.dcursor = 1
  for i, dl in ipairs(cached.dlines) do
    if dl.kind == "add" or dl.kind == "del" then
      state.dcursor = i
      break
    end
  end
end

local function refresh(state)
  state.cache = {}
  state.wchanges = git_changes() or state.wchanges
  state.commits = git_log() or state.commits
  if state.commit then
    state.commit_changes =
      git_commit_changes(state.commit.sha) or state.commit_changes
  end
  redraw(state) -- rebuild row maps before reloading the preview
  load_preview(state)
  redraw(state)
end

--- pane switching ----------------------------------------------------------

local PANE_NEXT = { files = "commits", commits = "comments", comments = "files" }

local function set_pane(state, pane)
  if pane == "diff" and not state.dlines then
    maki.ui.flash("No diff to focus")
    return
  end
  if state.pane == pane then
    return
  end
  state.pane = pane
  state.vstart = nil
  if pane ~= "diff" then
    state.src = pane
    load_preview(state)
  end
  redraw(state)
end

-- Toggles a directory row in the files / commit-files tree.
local function toggle_dir(state, dir)
  local set = state.pane == "commits" and state.ccollapsed or state.fcollapsed
  set[dir] = not set[dir] and true or nil
  redraw(state)
end

local function enter_commit(state)
  local sel = state.crow_map and state.crow_map[state.ccursor]
  local cm = type(sel) == "number" and state.commits[sel] or nil
  if not cm then
    return
  end
  local ch, err = git_commit_changes(cm.sha)
  if not ch then
    maki.ui.flash("commit diff failed: " .. tostring(err))
    return
  end
  state.saved_ccursor = state.ccursor
  state.commit = cm
  state.commit_changes = ch
  state.ccollapsed = {}
  state.ccursor = 1
  redraw(state) -- rebuild the commit-files row map
  for r = 1, state.cbuf:len() do
    if type(state.crow_map[r]) == "number" then
      state.ccursor = r
      break
    end
  end
  load_preview(state)
  redraw(state)
end

local function leave_commit(state)
  state.commit = nil
  state.commit_changes = nil
  state.ccursor = state.saved_ccursor or 1
  redraw(state)
  load_preview(state)
  redraw(state)
end

local function delete_selected_comment(state)
  local idx = state.mrow_map and state.mrow_map[state.mcursor]
  if not idx or not comments[idx] then
    maki.ui.flash("No comment selected")
    return
  end
  table.remove(comments, idx)
  maki.ui.flash("Comment deleted")
  if state.mcursor > 1 then
    state.mcursor = state.mcursor - 1
  end
  load_preview(state)
  redraw(state)
end

--- navigation --------------------------------------------------------------

local CURSOR_KEY = { files = "fcursor", commits = "ccursor", comments = "mcursor" }

local function active_view(state)
  if state.pane == "files" then
    return state.fcursor, state.frow_map, state.fbuf
  elseif state.pane == "commits" then
    return state.ccursor, state.crow_map, state.cbuf
  elseif state.pane == "comments" then
    return state.mcursor, state.mrow_map, state.mbuf
  end
  return state.dcursor, state.drow_map, state.rbuf
end

local function active_height(state)
  if state.pane == "files" then
    return state.fheight
  elseif state.pane == "commits" then
    return state.cheight
  elseif state.pane == "comments" then
    return state.mheight
  end
  return state.rheight
end

local function set_active_cursor(state, r)
  if state.pane == "diff" then
    if r ~= state.dcursor then
      state.dcursor = r
      if state.vstart then
        state.vcur = state.drow_map[r]
      end
      redraw(state)
    end
    return
  end
  local key = CURSOR_KEY[state.pane]
  if r ~= state[key] then
    state[key] = r
    load_preview(state)
    redraw(state)
  end
end

-- Rows in the diff pane where a change block (run of +/- lines) or a
-- comment starts, in display order.
local function block_rows(state)
  local rows = {}
  local dlines, ch = state.dlines, state.change
  if not dlines or not ch then
    return rows
  end
  local max = 0
  for r in pairs(state.drow_map) do
    max = math.max(max, r)
  end
  local prev_changed, prev_c = false, nil
  for r = 1, max do
    local i = state.drow_map[r]
    local dl = i and dlines[i]
    if dl and dl.kind == "hunk" then
      prev_changed, prev_c = false, nil
    elseif dl then
      local sides = state.drow_sides and state.drow_sides[r]
      local idxs = sides and { sides.old, sides.new } or { i }
      local changed, c = false, nil
      for _, k in pairs(idxs) do
        local kd = dlines[k]
        changed = changed or kd.kind == "add" or kd.kind == "del"
        c = c or comment_at(ch, kd)
      end
      if (changed and not prev_changed) or (c and c ~= prev_c) then
        rows[#rows + 1] = r
      end
      prev_changed, prev_c = changed, c
    end
  end
  return rows
end

-- Moves the diff cursor to the next (dir = 1) or previous (dir = -1)
-- change block or comment, wrapping around.
local function jump_block(state, dir)
  local rows = block_rows(state)
  if #rows == 0 then
    maki.ui.flash("No changes or comments in this diff")
    return
  end
  local target
  if dir > 0 then
    for _, r in ipairs(rows) do
      if r > state.dcursor then
        target = r
        break
      end
    end
    target = target or rows[1]
  else
    for k = #rows, 1, -1 do
      if rows[k] < state.dcursor then
        target = rows[k]
        break
      end
    end
    target = target or rows[#rows]
  end
  set_active_cursor(state, target)
end

-- From the diff pane, opens the next (dir = 1) or previous (dir = -1)
-- file in the source tree (Files, or the open commit's files).
local function step_file(state, dir)
  local ckey, map
  if state.src == "files" then
    ckey, map = "fcursor", state.frow_map
  elseif state.src == "commits" and state.commit then
    ckey, map = "ccursor", state.crow_map
  else
    maki.ui.flash("No file list to step through")
    return
  end
  local max = 0
  for r in pairs(map) do
    max = math.max(max, r)
  end
  local r = state[ckey] + dir
  while r >= 1 and r <= max do
    if type(map[r]) == "number" then
      state[ckey] = r
      state.vstart = nil
      state.vshift = nil
      load_preview(state)
      redraw(state)
      return
    end
    r = r + dir
  end
  maki.ui.flash(dir > 0 and "Last file" or "First file")
end

local function move(state, dir, count)
  count = count or 1
  local cursor, row_map, buf = active_view(state)
  local r = cursor
  local total = buf:len()
  for _ = 1, count do
    local nr = r + dir
    while nr >= 1 and nr <= total and not row_map[nr] do
      nr = nr + dir
    end
    if row_map[nr] then
      r = nr
    else
      break
    end
  end
  set_active_cursor(state, r)
end

local function jump(state, to_end)
  local cursor, row_map, buf = active_view(state)
  local best
  local from, to, step = 1, buf:len(), 1
  if to_end then
    from, to, step = buf:len(), 1, -1
  end
  for r = from, to, step do
    if row_map[r] then
      best = r
      break
    end
  end
  if best then
    set_active_cursor(state, best)
  end
end

--- comment editing ---------------------------------------------------------

local function open_comment_editor(state)
  local at = state.drow_map[state.dcursor]
  local dl = state.dlines and state.dlines[at]
  if not dl or dl.kind == "hunk" then
    maki.ui.flash("Move onto a diff line first (j/k)")
    return
  end

  local from, to
  if state.vstart then
    from = math.min(state.vstart, state.vcur)
    to = math.max(state.vstart, state.vcur)
  else
    from, to = at, at
  end

  local input = TextInput.new()
  local existing, existing_idx = comment_at(state.change, state.dlines[to])
  local label
  if existing then
    input:insert_text(existing.text)
    label = line_range_label(existing)
    from, to = nil, nil -- editing keeps the original range
  else
    label = line_range_label(make_comment(state.change, state.dlines, from, to, ""))
  end

  state.centry = {
    input = input,
    from = from,
    to = to,
    at = at,
    existing_idx = existing_idx,
    label = label,
  }
  state.vstart = nil
  redraw(state)
end

local function save_comment(state)
  local e = state.centry
  local text = e.input:value():match("^%s*(.-)%s*$")
  state.centry = nil
  if text == "" then
    redraw(state)
    return
  end
  if e.existing_idx then
    comments[e.existing_idx].text = text
  else
    comments[#comments + 1] =
      make_comment(state.change, state.dlines, e.from, e.to, text)
  end
  redraw(state)
end

local function delete_comment(state)
  local dl = state.dlines and state.dlines[state.drow_map[state.dcursor]]
  if not dl then
    return
  end
  local _, idx = comment_at(state.change, dl)
  if idx then
    table.remove(comments, idx)
    maki.ui.flash("Comment deleted")
    redraw(state)
  else
    maki.ui.flash("No comment on this line")
  end
end

--- windows -----------------------------------------------------------------

local function layout()
  local sz = maki.ui.terminal_size()
  local w = sz.cols
  local h = math.max(sz.rows - 2, 10)
  local lw = math.max(28, math.min(46, math.floor(w * 0.30)))
  local rw = w - lw
  local row = 0
  local col = 0
  local fh = math.max(math.floor(h * 0.38), 5)
  local ch = math.max(math.floor(h * 0.34), 5)
  local mh = math.max(h - fh - ch, 4)
  return {
    lw = lw,
    rw = rw,
    h = h,
    fh = fh,
    ch = ch,
    mh = mh,
    row = row,
    col = col,
  }
end

-- Opens (or reopens) all panes. Only the Files window takes focus and
-- receives keys; the other windows are display-only.
local function open_windows(state)
  for _, w in ipairs({ "fwin", "cwin", "mwin", "rwin", "swin" }) do
    if state[w] then
      state[w]:close()
    end
  end
  local L = layout()
  state.swin = maki.ui.open_win(state.sbuf, {
    width = L.lw + L.rw,
    height = 1,
    row = L.row + L.h,
    col = L.col,
    anchor = "NW",
    border = "none",
    focus = false,
  })
  state.rwin = maki.ui.open_win(state.rbuf, {
    title = " Diff ",
    width = L.rw,
    height = L.h,
    row = L.row,
    col = L.col + L.lw,
    anchor = "NW",
    focus = false,
  })
  state.cwin = maki.ui.open_win(state.cbuf, {
    title = " Commits ",
    width = L.lw,
    height = L.ch,
    row = L.row + L.fh,
    col = L.col,
    anchor = "NW",
    focus = false,
  })
  state.mwin = maki.ui.open_win(state.mbuf, {
    title = " Comments ",
    width = L.lw,
    height = L.mh,
    row = L.row + L.fh + L.ch,
    col = L.col,
    anchor = "NW",
    focus = false,
  })
  state.fwin = maki.ui.open_win(state.fbuf, {
    title = " Files ",
    width = L.lw,
    height = L.fh,
    row = L.row,
    col = L.col,
    anchor = "NW",
    focus = true,
  })
  state.lwidth = state.fwin.width
  state.rwidth = state.rwin.width
  state.fheight = state.fwin.height
  state.cheight = state.cwin.height
  state.mheight = state.mwin.height
  state.rheight = state.rwin.height
  state.term = maki.ui.terminal_size()
end

local MOVE_KEYS = {
  ["<Up>"] = true, ["<Down>"] = true, k = true, j = true,
  ["<PageUp>"] = true, ["<PageDown>"] = true,
  g = true, G = true, ["<Home>"] = true, ["<End>"] = true,
  ["<Tab>"] = true, ["<S-Tab>"] = true,
}

--- help overlay ------------------------------------------------------------

local HELP = {
  {
    "Global",
    {
      { "?", "toggle this help" },
      { "Tab", "cycle Files → Commits → Comments (left panes)" },
      { "↑ ↓ / k j", "move cursor" },
      { "PgUp PgDn", "move one page" },
      { "g / Home", "jump to top" },
      { "G / End", "jump to bottom" },
      { "s", "submit comments to a new session" },
      { "q / Ctrl-C", "close review" },
    },
  },
  {
    "Files / Commits / Comments",
    {
      { "Enter / l / →", "open diff, expand dir, open commit" },
      { "h / ←", "collapse dir, leave commit" },
      { "r", "refresh from git" },
      { "d", "delete comment (Comments pane)" },
      { "Esc", "leave commit, or close review" },
    },
  },
  {
    "Diff",
    {
      { "Tab / Shift-Tab", "next / previous change block or comment" },
      { "t", "toggle unified / side-by-side view" },
      { "f", "toggle changed hunks / whole file" },
      { "n / p", "next / previous file in the tree" },
      { "c / Enter", "comment on line or selection" },
      { "v", "start / cancel range selection" },
      { "Shift-↑ ↓", "select range (ends on next plain move)" },
      { "d", "delete comment under cursor" },
      { "h / ← / Esc", "cancel selection, or go back" },
    },
  },
  {
    "Comment editor",
    {
      { "Enter", "save comment" },
      { "Esc / Ctrl-C", "cancel" },
    },
  },
}

local function is_help_key(key)
  return key == "?"
end

local function close_help(state)
  if state.hwin then
    state.hwin:close()
    state.hwin = nil
  end
end

local function open_help(state)
  close_help(state)
  local kw = 0
  for _, sec in ipairs(HELP) do
    for _, item in ipairs(sec[2]) do
      kw = math.max(kw, display_len(item[1]))
    end
  end
  local buf = maki.ui.buf()
  local width = 0
  for i, sec in ipairs(HELP) do
    if i > 1 then
      buf:line("")
    end
    buf:line({ { " " .. sec[1], "accent" } })
    for _, item in ipairs(sec[2]) do
      local pad = string.rep(" ", kw - display_len(item[1]))
      buf:line({ { "   " .. item[1] .. pad, "warning" }, { "   " .. item[2] } })
      width = math.max(width, 6 + kw + display_len(item[2]))
    end
  end
  local sz = maki.ui.terminal_size()
  local w = math.min(width + 4, sz.cols - 2)
  local h = math.min(buf:len() + 2, sz.rows - 2)
  state.hwin = maki.ui.open_win(buf, {
    title = " Review shortcuts ",
    title_pos = "center",
    border = "double",
    width = w,
    height = h,
    row = math.max(math.floor((sz.rows - h) / 2), 0),
    col = math.max(math.floor((sz.cols - w) / 2), 0),
    anchor = "NW",
    zindex = 200,
    focus = false,
    footer = { { "?/Esc", "close" } },
  })
end

--- main loop ---------------------------------------------------------------

local function open_review()
  local changes, err = git_changes()
  if not changes then
    maki.ui.flash(tostring(err))
    return
  end

  local state = {
    fbuf = maki.ui.buf(),
    cbuf = maki.ui.buf(),
    mbuf = maki.ui.buf(),
    rbuf = maki.ui.buf(),
    sbuf = maki.ui.buf(),
    pane = "files",
    src = "files",
    wchanges = changes,
    commits = git_log() or {},
    fcursor = 1,
    ccursor = 1,
    mcursor = 1,
    dcursor = 1,
    frow_map = {},
    crow_map = {},
    mrow_map = {},
    drow_map = {},
    fcollapsed = {},
    ccollapsed = {},
    cache = {},
  }
  open_windows(state)
  redraw(state) -- build row maps before the first preview
  for r = 1, state.fbuf:len() do
    if type(state.frow_map[r]) == "number" then
      state.fcursor = r -- start on the first file, not a directory row
      break
    end
  end
  load_preview(state)
  redraw(state)

  while true do
    local ev = state.fwin:recv()
    if not ev or ev.type == "close" then
      break
    end

    if ev.type == "resize" then
      -- Windows emit a resize event on their first layout pass too; only
      -- reopen when the terminal itself changed, or we'd loop forever
      -- (reopen -> initial resize -> reopen ...).
      local sz = maki.ui.terminal_size()
      if sz.cols ~= state.term.cols or sz.rows ~= state.term.rows then
        local had_help = state.hwin ~= nil
        close_help(state)
        open_windows(state)
        if had_help then
          open_help(state)
        end
      end
      redraw(state)
      continue
    end

    if ev.type == "paste" and state.centry then
      state.centry.input:insert_text(ev.text)
      redraw(state)
      continue
    end

    if ev.type ~= "key" then
      continue
    end
    local key = ev.key

    -- Help overlay swallows keys while open; ?/Esc/q close it.
    if state.hwin then
      if is_help_key(key) or key == "<Esc>" or key == "q" then
        close_help(state)
      end
      continue
    end
    if key == "?" and not state.centry then
      open_help(state)
      continue
    end

    -- Comment editor owns the keyboard while open.
    if state.centry then
      if key == "<CR>" then
        save_comment(state)
      elseif key == "<Esc>" or key == "<C-c>" then
        state.centry = nil
        redraw(state)
      else
        if state.centry.input:handle_key(key) ~= TextInput.Result.IGNORED then
          redraw(state)
        end
      end
      continue
    end

    -- A Shift-arrow selection ends with the next plain movement key, the
    -- closest a terminal gets to "Shift released".
    if state.vshift and MOVE_KEYS[key] then
      state.vstart = nil
      state.vshift = nil
      redraw(state)
    end

    if key == "<Up>" or key == "k" then
      move(state, -1)
    elseif key == "<Down>" or key == "j" then
      move(state, 1)
    elseif key == "<PageUp>" then
      move(state, -1, math.max(active_height(state) - 2, 1))
    elseif key == "<PageDown>" then
      move(state, 1, math.max(active_height(state) - 2, 1))
    elseif key == "g" or key == "<Home>" then
      jump(state, false)
    elseif key == "G" or key == "<End>" then
      jump(state, true)
    elseif key == "<Tab>" or key == "<S-Tab>" then
      if state.pane == "diff" then
        jump_block(state, key == "<Tab>" and 1 or -1)
      elseif key == "<Tab>" then
        set_pane(state, PANE_NEXT[state.pane])
      end
    elseif key == "s" then
      if submit(state) then
        return
      end
      redraw(state)
    elseif key == "q" or key == "<C-c>" then
      break
    elseif state.pane ~= "diff" then -- one of the left panels
      if key == "<CR>" or key == "l" or key == "<Right>" then
        if state.pane == "commits" and not state.commit then
          enter_commit(state)
        elseif state.pane == "comments" then
          maki.ui.flash("d deletes the selected comment")
        else
          local cursor, row_map = active_view(state)
          local sel = row_map[cursor]
          if type(sel) == "table" and sel.dir then
            toggle_dir(state, sel.dir)
          else
            set_pane(state, "diff")
          end
        end
      elseif key == "d" and state.pane == "comments" then
        delete_selected_comment(state)
      elseif key == "r" then
        refresh(state)
      elseif key == "h" or key == "<Left>" then
        local cursor, row_map = active_view(state)
        local sel = row_map[cursor]
        local set = state.pane == "commits" and state.ccollapsed
          or state.fcollapsed
        if
          (state.pane == "files" or (state.pane == "commits" and state.commit))
          and type(sel) == "table"
          and sel.dir
          and not set[sel.dir]
        then
          toggle_dir(state, sel.dir) -- collapse the directory under the cursor
        elseif state.pane == "commits" and state.commit then
          leave_commit(state)
        end
      elseif key == "<Esc>" then
        if state.pane == "commits" and state.commit then
          leave_commit(state)
        else
          break
        end
      end
    else -- diff pane
      if key == "<S-Up>" or key == "<S-Down>" then
        if not state.vstart then
          state.vstart = state.drow_map[state.dcursor]
          state.vcur = state.vstart
          state.vshift = state.vstart ~= nil
        end
        move(state, key == "<S-Up>" and -1 or 1)
        redraw(state)
      elseif key == "n" or key == "p" then
        step_file(state, key == "n" and 1 or -1)
      elseif key == "f" then
        local cur = state.dlines and state.dlines[state.drow_map[state.dcursor] or 0]
        full_file = not full_file
        state.vstart = nil
        state.vshift = nil
        load_preview(state)
        redraw(state)
        if cur and cur.kind ~= "hunk" then
          for r, i in pairs(state.drow_map) do
            local dl = state.dlines[i]
            if dl.kind == cur.kind and dl.old_ln == cur.old_ln and dl.new_ln == cur.new_ln then
              state.dcursor = r
              break
            end
          end
          redraw(state)
        end
        maki.ui.flash(full_file and "Showing whole file" or "Showing changed hunks only")
      elseif key == "t" then
        split_view = not split_view
        state.vstart = nil
        state.vshift = nil
        local anchor = state.drow_map[state.dcursor]
        redraw(state)
        for r, i in pairs(state.drow_map) do
          local sides = state.drow_sides and state.drow_sides[r]
          if i == anchor or (sides and (sides.old == anchor or sides.new == anchor)) then
            state.dcursor = r
            break
          end
        end
        redraw(state)
      elseif key == "c" or key == "<CR>" then
        open_comment_editor(state)
      elseif key == "v" then
        state.vshift = nil
        if state.vstart then
          state.vstart = nil
        else
          state.vstart = state.drow_map[state.dcursor]
          state.vcur = state.vstart
        end
        redraw(state)
      elseif key == "d" then
        delete_comment(state)
      elseif key == "h" or key == "<Left>" or key == "<Esc>" then
        if state.vstart then
          state.vstart = nil
          redraw(state)
        else
          set_pane(state, state.src)
        end
      end
    end
  end

  close_help(state)
  for _, w in ipairs({ "fwin", "cwin", "mwin", "rwin", "swin" }) do
    if state[w] then
      state[w]:close()
    end
  end
end

--- registration ------------------------------------------------------------

local function open_review_safe()
  local ok, err = pcall(open_review)
  if not ok then
    maki.log.error("review crashed: " .. tostring(err))
    maki.ui.flash("review error: " .. tostring(err))
  end
end

maki.api.register_command({
  name = "/review",
  description = "Review changes vs HEAD, comment on diff lines, send fixes to maki",
  handler = open_review_safe,
})


-- Nudge after each turn when the working tree changed.
local last_sig = nil
maki.api.create_autocmd("TurnEnd", {
  callback = function()
    maki.async.run(function()
      local out = run(
        "git diff --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null"
      )
      if not out then
        return
      end
      local n = 0
      for _ in out:gmatch("[^\n]+") do
        n = n + 1
      end
      if n > 0 and out ~= last_sig then
        last_sig = out
        maki.ui.flash(n .. " file(s) changed — /review to inspect & comment")
      end
    end)
  end,
})
