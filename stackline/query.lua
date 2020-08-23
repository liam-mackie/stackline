-- NOTES: Functionality from this file can be completely factored out into
-- stack.lua and stackline.lua. In fact, I've already done this once, but was
-- riding a bit too fast and found myself in a place where nothing worked, and I
-- didn't know why. So, this mess lives another day. Conceptually, it'll be
-- pretty easy to put this stuff where it belongs.
local u = require 'stackline.lib.utils'

local scriptPath = hs.configdir .. '/stackline/bin/yabai-get-stack-idx'

-- stackline modules
local Window = require 'stackline.stackline.window'
local Query = {}

function Query:getWinStackIdxs() -- {{{
    -- call out to yabai to get stack-indexes
    hs.task.new("/bin/dash", function(_code, stdout, _stderr)
        self.winStackIdxs = hs.json.decode(stdout)
    end, {scriptPath}):start()
end -- }}}

function Query:groupWindows(ws) -- {{{
    -- Given windows from hs.window.filter: 
    --    1. Create stackline window objects
    --    2. Group wins by `stackId` prop (aka top-left frame coords) 
    --    3. If at least one such group, also group wins by app (to workaround hs bug unfocus event bug)
    local byStack
    local byApp

    local windows = u.map(ws, function(w)
        return Window:new(w)
    end)

    -- See 'stackId' def @ /window.lua:233
    byStack = u.filter(u.groupBy(windows, 'stackId'), u.greaterThan(1)) -- stacks have >1 window, so ignore 'groups' of 1

    if u.length(byStack) > 0 then
        -- app names are keys in group
        local stackedWins = u.reduce(u.values(byStack), u.concat)
        byApp = u.groupBy(stackedWins, 'app')
    end

    self.appWindows = byApp
    self.stacks = byStack
end -- }}}

function Query:removeGroupedWin(win)
    self.stacks = u.map(self.stacks, function(stack)
        return u.filter(stack, function(w)
            return w.id ~= win.id
        end)
    end)
end

function Query:mergeWinStackIdxs() -- {{{
    -- merge windowID <> stack-index mapping queried from yabai into window objs

    function assignStackIndex(win)
        local stackIdx = self.winStackIdxs[tostring(win.id)]

        if stackIdx == 0 then
            -- DONE: Fix error stackline/window.lua:95: attempt to perform arithmetic on a nil value (field 'stackIdx')
            -- Remove windows with stackIdx == 0. Such windows overlap exactly with
            -- other (potentially stacked) windows, and so are grouped with them,
            -- but they are NOT stacked according to yabai. 
            -- Windows that belong to a *real* stack have stackIdx > 0.
            self:removeGroupedWin(win)
        end

        -- set the stack idx 
        win.stackIdx = stackIdx
    end

    u.each(self.stacks, function(stack)
        u.each(stack, assignStackIndex)
    end)

end -- }}}

function shouldRestack(new) -- {{{
    -- Analyze self.stacks to determine if a stack refresh is needed
    --  • change num stacks (+/-)
    --  • changes to existing stack
    --    • change position
    --    • change num windows (win added / removed)

    local curr = Sm:getSummary()
    new = Sm:getSummary(u.values(new))

    if curr.numStacks ~= new.numStacks then
        print('num stacks changed')
        return true
    end

    if not u.equal(curr.topLeft, new.topLeft) then
        print('position changed')
        return true
    end

    if not u.equal(curr.numWindows, new.numWindows) then
        print('num windows changed')
        return true
    end
end -- }}}

function Query:windowsCurrentSpace() -- {{{
    self:groupWindows(wfd:getWindows()) -- set self.stacks & self.appWindows

    local extantStacks = Sm:get()
    local extantStackSummary = Sm:getSummary()
    local extantStackExists = extantStackSummary.numStacks > 0

    local shouldRefresh = extantStackExists and
                              shouldRestack(self.stacks, extantStacks) or true
    if shouldRefresh then
        -- TODO: revisit in a future update. This is kind of an edge case — there are bigger fish to fry.
        -- stacksMgr:dimOccluded() 
        self:getWinStackIdxs() -- set self.winStackIdxs (async shell call to yabai)

        function whenStackIdxDone()
            self:mergeWinStackIdxs() -- Add the stack indexes from yabai to the hs window data
            Sm:ingest(self.stacks, self.appWindows, extantStackExists) -- hand over to the Stack module
        end

        local pollingInterval = 0.1
        hs.timer.waitUntil(function()
            return self.winStackIdxs ~= nil
        end, whenStackIdxDone, pollingInterval)
    end
end -- }}}

return Query