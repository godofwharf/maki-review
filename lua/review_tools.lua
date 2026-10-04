-- Agent tools over the persistent /review store (review_store.lua).
--
-- Scope is always derived from the session's working directory (git
-- toplevel + branch); callers cannot pick another repo/branch. Comment ids
-- outside that scope are reported as not found.

local store = require("review_store")

local function err(msg)
  return { llm_output = "error: " .. tostring(msg), is_error = true }
end

local function scope()
  local ok, cwd = pcall(maki.uv.cwd)
  return store.scope(ok and cwd or nil)
end

local function actor(ctx)
  local id
  if ctx then
    for _, m in ipairs({ "session_id", "task_id" }) do
      local f = ctx[m]
      if type(f) == "function" then
        local ok, v = pcall(f, ctx)
        if ok and type(v) == "string" and v ~= "" then
          id = id and (id .. "/" .. v) or v
        end
      end
    end
  end
  if not id or not id:find("/") then
    local ok, sid = pcall(maki.session.current)
    if ok and type(sid) == "string" then
      id = (id and id ~= "main") and (sid .. "/" .. id) or sid
    end
  end
  return { kind = "agent", id = "maki:" .. (id or "unknown") }
end

-- Open review for the scope, else the most recent resolved one.
local function current_review(sc)
  local r, e = store.open_review(sc, nil, false)
  if e then
    return nil, e
  end
  if r then
    return r
  end
  local rows = store.list_reviews({ scope = sc, include_hidden = true }) or {}
  for _, rr in ipairs(rows) do
    if rr.status == "resolved" then
      return rr
    end
  end
  return nil
end

local function loc(c)
  local s = c.file_path .. ":" .. tostring(c.span_from or "?")
  if c.span_to and c.span_to ~= c.span_from then
    s = s .. "-" .. c.span_to
  end
  if c.side == "old" then
    s = s .. " (removed lines)"
  end
  if c.target_kind == "commit" then
    s = s .. " @commit " .. tostring(c.target_sha)
  end
  return s
end

local function one_line(s, max)
  s = tostring(s or ""):gsub("%s+", " ")
  if #s > max then
    s = s:sub(1, max - 1) .. "…"
  end
  return s
end

local function describe(c, full)
  local l = {
    "[" .. c.id .. "] " .. c.status .. "  " .. loc(c) .. "  by " .. c.author_kind .. " " .. c.author_id,
  }
  if c.status == "in_progress" and c.claimed_by then
    l[#l + 1] = "  claimed by " .. c.claimed_by
  end
  if full then
    l[#l + 1] = "  body:"
    for bl in (c.body .. "\n"):gmatch("(.-)\n") do
      l[#l + 1] = "    " .. bl
    end
    if c.resolution_note then
      l[#l + 1] = "  resolution: " .. c.resolution_note
        .. (c.resolution_sha and (" (" .. c.resolution_sha .. ")") or "")
    end
    if c.blob_sha then
      l[#l + 1] = "  blob at comment time: " .. c.blob_sha
    end
    if c.snippet and c.snippet ~= "" then
      l[#l + 1] = "  snippet:"
      l[#l + 1] = "```diff"
      l[#l + 1] = c.snippet
      l[#l + 1] = "```"
    end
  else
    l[#l + 1] = "  " .. one_line(c.body, 200)
  end
  return table.concat(l, "\n")
end

-- Runs a scoped mutation and turns the result into tool output.
local function mutate(input, ctx, fn, verb)
  if type(input.id) ~= "string" or input.id == "" then
    return err("id is required")
  end
  local sc, se = scope()
  if not sc then
    return err(se)
  end
  local me = actor(ctx)
  local ok, info = fn(sc, me)
  if ok == nil then
    return err(info)
  end
  if not ok then
    local c = store.get_comment(input.id, sc)
    if not c then
      return err("comment " .. input.id .. " not found in this repo/worktree/branch")
    end
    local why = "comment is " .. c.status
    if c.status == "in_progress" and c.claimed_by then
      why = why .. " (claimed by " .. c.claimed_by .. ")"
    end
    return err("could not " .. verb .. " " .. input.id .. ": " .. why)
  end
  local out = "ok: " .. input.id .. " " .. verb .. (info and info.status and (" → " .. info.status) or "")
  if info and info.review_status == "resolved" then
    out = out .. "\nAll comments in this review are closed; the review is now resolved."
  end
  return { llm_output = out }
end

local function id_schema(extra, required)
  local props = { id = { type = "string", description = "Comment id (from review_list_comments)" } }
  for k, v in pairs(extra or {}) do
    props[k] = v
  end
  return { type = "object", properties = props, required = required or { "id" } }
end

maki.api.register_tool({
  name = "review_list_comments",
  description = [[List persistent code-review comments for the current git worktree and branch (left by humans via /review or by agents).
Defaults to actionable comments (open + in_progress). Use review_get_comment for full details, review_claim_comment before working on one.]],
  schema = {
    type = "object",
    properties = {
      status = {
        type = "string",
        description = "Filter: open, in_progress, resolved, stale, wontfix, active (open+in_progress, default) or all",
      },
      file = { type = "string", description = "Only comments on this repo-relative file path" },
    },
  },
  handler = function(input)
    local sc, se = scope()
    if not sc then
      return err(se)
    end
    local review, re = current_review(sc)
    if re then
      return err(re)
    end
    if not review then
      return { llm_output = "No review for branch " .. sc.branch .. " in " .. sc.worktree_path .. "." }
    end
    local st = input.status or "active"
    local statuses
    if st == "active" then
      statuses = { "open", "in_progress" }
    elseif st ~= "all" then
      local valid = false
      for _, s in ipairs(store.STATUSES) do
        valid = valid or s == st
      end
      if not valid then
        return err("unknown status " .. st)
      end
      statuses = { st }
    end
    local rows, le = store.list_comments(review.id, { statuses = statuses, file = input.file })
    if not rows then
      return err(le)
    end
    local out = {
      "Review " .. review.id .. " (" .. review.status .. ") on " .. review.branch
        .. ": " .. tostring(review.n_active) .. " active / " .. tostring(review.n_total) .. " total",
    }
    if #rows == 0 then
      out[#out + 1] = "No " .. st .. " comments."
    end
    for _, c in ipairs(rows) do
      out[#out + 1] = describe(c, false)
    end
    return { llm_output = table.concat(out, "\n") }
  end,
})

maki.api.register_tool({
  name = "review_get_comment",
  description = "Get one review comment with its full body, code snippet, resolution, and status history.",
  schema = id_schema(),
  handler = function(input)
    local sc, se = scope()
    if not sc then
      return err(se)
    end
    local c, ce = store.get_comment(input.id, sc)
    if ce then
      return err(ce)
    end
    if not c then
      return err("comment " .. tostring(input.id) .. " not found in this repo/worktree/branch")
    end
    local out = { describe(c, true), "  history:" }
    for _, e in ipairs(store.events(c.id) or {}) do
      out[#out + 1] = "    "
        .. (e.from_status or "-")
        .. " → "
        .. tostring(e.to_status)
        .. " by "
        .. e.actor_kind
        .. " "
        .. e.actor_id
        .. (e.note and (": " .. one_line(e.note, 200)) or "")
    end
    return { llm_output = table.concat(out, "\n") }
  end,
})

maki.api.register_tool({
  name = "review_claim_comment",
  description = [[Claim a review comment (status → in_progress) before working on it, so other agents skip it.
Fails if another agent holds a claim younger than 30 minutes. Release with review_release_comment if you give up.]],
  schema = id_schema(),
  handler = function(input, ctx)
    return mutate(input, ctx, function(sc, me)
      return store.claim(input.id, me, sc)
    end, "claimed")
  end,
})

maki.api.register_tool({
  name = "review_release_comment",
  description = "Release your claim on a review comment, putting it back to open.",
  schema = id_schema({ note = { type = "string", description = "Why you are releasing it" } }),
  handler = function(input, ctx)
    return mutate(input, ctx, function(sc, me)
      return store.release(input.id, me, sc, input.note)
    end, "released")
  end,
})

maki.api.register_tool({
  name = "review_resolve_comment",
  description = "Mark a review comment resolved after applying the fix. Include a short note of what changed and the commit sha if committed.",
  schema = id_schema({
    note = { type = "string", description = "What was done to address the comment" },
    sha = { type = "string", description = "Commit containing the fix, if any" },
  }, { "id", "note" }),
  handler = function(input, ctx)
    return mutate(input, ctx, function(sc, me)
      return store.set_status(input.id, "resolved", me, {
        note = input.note,
        sha = input.sha,
        scope = sc,
        respect_claim = true,
      })
    end, "resolved")
  end,
})

maki.api.register_tool({
  name = "review_mark_stale",
  description = "Mark a review comment stale: the code it refers to changed or no longer exists, so it no longer applies.",
  schema = id_schema({ reason = { type = "string", description = "Why it no longer applies" } }, { "id", "reason" }),
  handler = function(input, ctx)
    return mutate(input, ctx, function(sc, me)
      return store.set_status(input.id, "stale", me, {
        note = input.reason,
        scope = sc,
        respect_claim = true,
      })
    end, "marked stale")
  end,
})

maki.api.register_tool({
  name = "review_reopen_comment",
  description = "Reopen a resolved/stale/wontfix review comment (e.g. the fix was incomplete).",
  schema = id_schema({ note = { type = "string", description = "Why it is reopened" } }, { "id", "note" }),
  handler = function(input, ctx)
    return mutate(input, ctx, function(sc, me)
      return store.set_status(input.id, "open", me, { note = input.note, scope = sc })
    end, "reopened")
  end,
})

local SNIPPET_NEW = 'sed -n "$1,$2p" -- "$3"'
local SNIPPET_OLD = 'git show "HEAD:$3" | sed -n "$1,$2p"'

maki.api.register_tool({
  name = "review_add_comment",
  description = [[Add a review comment on lines of a file in the current worktree (persisted, visible in /review).
Lines refer to the current working-tree file (side "new", default) or to HEAD's version (side "old").]],
  schema = {
    type = "object",
    properties = {
      file = { type = "string", description = "Repo-relative file path" },
      from = { type = "integer", description = "First line (1-based)" },
      to = { type = "integer", description = "Last line (default: from)" },
      body = { type = "string", description = "Comment text" },
      side = { type = "string", enum = { "new", "old" }, description = "new (default) or old" },
    },
    required = { "file", "from", "body" },
  },
  handler = function(input, ctx)
    local sc, se = scope()
    if not sc then
      return err(se)
    end
    local file = tostring(input.file or "")
    if file:sub(1, #sc.worktree_path + 1) == sc.worktree_path .. "/" then
      file = file:sub(#sc.worktree_path + 2)
    end
    if file == "" or file:sub(1, 1) == "/" or file:find("%.%./") or file:sub(1, 3) == "../" then
      return err("file must be a path inside the worktree")
    end
    local from = math.floor(tonumber(input.from) or 0)
    local to = math.floor(tonumber(input.to) or from)
    if from < 1 or to < from then
      return err("invalid line range")
    end
    if type(input.body) ~= "string" or not input.body:find("%S") then
      return err("body is required")
    end
    local side = input.side == "old" and "old" or "new"

    local lo, hi = math.max(from - 2, 1), to + 2
    local text, te = store.sh(side == "old" and SNIPPET_OLD or SNIPPET_NEW, sc.worktree_path,
      tostring(lo), tostring(hi), file)
    if not text then
      return err("cannot read " .. file .. ": " .. tostring(te))
    end
    local snippet, ln = {}, lo
    if text ~= "" and text:sub(-1) ~= "\n" then
      text = text .. "\n"
    end
    for l in text:gmatch("([^\n]*)\n") do
      snippet[#snippet + 1] = " " .. l .. ((ln >= from and ln <= to) and "  <<< comment applies here" or "")
      ln = ln + 1
    end
    if ln <= from then
      return err(file .. " has fewer than " .. from .. " lines")
    end
    local blob = store.sh(
      side == "old" and 'git rev-parse "HEAD:$1"' or 'git hash-object -- "$1"',
      sc.worktree_path,
      file
    )
    blob = blob and blob:match("^%s*(%x+)%s*$")

    local me = actor(ctx)
    local review = current_review(sc)
    if review and review.status == "resolved" then
      local rr = store.reopen_review(review.id)
      review = (rr and rr.status == "open") and rr or nil
    end
    if not review then
      local re
      review, re = store.open_review(sc, me, true)
      if not review then
        return err(re)
      end
    end
    local anchor = side == "old" and { old_start = from, old_end = to } or { new_start = from, new_end = to }
    local c, ae = store.add_comment(review.id, {
      file_path = file,
      target_kind = "worktree",
      side = side,
      span_from = from,
      span_to = to,
      snippet = table.concat(snippet, "\n"),
      anchor = anchor,
      blob_sha = blob,
      body = input.body,
    }, me)
    if not c then
      return err(ae)
    end
    return { llm_output = "ok: added comment " .. c.id .. " at " .. loc(c) }
  end,
})
