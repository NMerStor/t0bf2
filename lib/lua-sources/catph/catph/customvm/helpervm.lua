--
-- customvm/helpervm.lua
--


local HelperVM = {}


local CAT_ARITH = 1
local CAT_TABLE = 2
local CAT_CALL  = 3
local CAT_FLOW  = 4

local CATEGORY = {}
-- Arithmetic
for _, op in ipairs({33,34,35,36,37,38,81,49,50,51,52}) do CATEGORY[op] = CAT_ARITH end
-- Table
for _, op in ipairs({13,14,15,16,17,18,53,55}) do CATEGORY[op] = CAT_TABLE end
-- Call/closure/upval/varargs
for _, op in ipairs({9,10,11,19,20,21,22,63}) do CATEGORY[op] = CAT_CALL end
-- Flow (loads, globals, moves, jumps, loops)
for _, op in ipairs({2,3,4,5,6,7,8,23,24,25,26,27,28,29,30,31,32,56,57,58}) do CATEGORY[op] = CAT_FLOW end
-- Super ops
for _, op in ipairs({82,83}) do CATEGORY[op] = CAT_ARITH end   -- ADDMOVE, MOVE_ADD
for _, op in ipairs({84,85}) do CATEGORY[op] = CAT_TABLE end   -- GETTKS_MOVE, LOADK_MOVE

HelperVM.CATEGORY = CATEGORY
HelperVM.CAT_ARITH = CAT_ARITH
HelperVM.CAT_TABLE = CAT_TABLE
HelperVM.CAT_CALL  = CAT_CALL
HelperVM.CAT_FLOW  = CAT_FLOW


function HelperVM.splitHandlers(handlers)
    local cats = { [CAT_ARITH]={}, [CAT_TABLE]={}, [CAT_CALL]={}, [CAT_FLOW]={} }
    for _, hd in ipairs(handlers) do
        local cat = CATEGORY[hd.op] or CAT_FLOW  -- unknown -> flow
        cats[cat][#cats[cat]+1] = hd
    end
    return cats
end


function HelperVM.categoryOf(op)
    return CATEGORY[op] or CAT_FLOW
end

return HelperVM
