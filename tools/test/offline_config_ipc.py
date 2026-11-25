"""Offline Lua 5.4 regression; only extracted functions and fake I/O run."""
from pathlib import Path
from lupa.lua54 import LuaRuntime

root = Path(__file__).resolve().parents[2]
s = (root / 'src/lua/main.lua').read_text(encoding='utf8')
lua = LuaRuntime()
def part(start, end):
    a = s.index(start)
    return s[a:s.index(end, a)]

lua.execute('''local reads=0; local RUNTIME={clock=0};local raw='quick_speed=500;real\\r\\nhighlight_rgb = #abcdef\\nquick_speed=20'
local function readFirst() reads=reads+1; return raw end
''' + part('local config =', '-- ---------------------------------------------------------------- 1)') + part('local function iniString', 'local function toLinear') + '''
for i=1,500 do assert(iniNumber('quick_speed',3)==500); assert(iniString('highlight_rgb','x')=='abcdef') end
assert(reads==1 and iniNumber('missing',7)==7);raw=nil;RUNTIME.clock=.5;assert(iniNumber('quick_speed',3)==500 and reads==2)
raw='quick_speed=100';RUNTIME.clock=.9;assert(iniNumber('quick_speed',3)==500);RUNTIME.clock=1;assert(iniNumber('quick_speed',3)==100 and reads==3)
''')
print('PASS 1000 lookups / 1 read, color, first key, read failure and hot refresh')

lua.execute('''local fail=true;local count={};local inFight=true;local function writeFile(k,v) count[k]=(count[k] or 0)+1;return not fail end
''' + part('local lastMap = nil', 'local shownChain') + '''
writeBattleFlag();assert(fightFlag==nil and battleFlag==nil);fail=false;writeBattleFlag();writeBattleFlag();assert(fightFlag and battleFlag and count['fight.flag']==2 and count['battle.flag']==2)
inFight=false;writeBattleFlag();assert(not fightFlag and not battleFlag)
''')
print('PASS battle/fight flags retry until written; no repeat on success')

lua.execute('''local old,errno,writable,reply,calls=true,13,false,'a|7',0;local DIR='';local vm={GetAddress=function()return 10 end};local GIFT={bridge=function() calls=calls+1;reply='a|9' end}
local os={remove=function() if old then return nil,'denied',errno end;reply=nil;return true end};local function writeFile() return writable end;local function readFirst() return reply end
local function receiver() local npc=-1
''' + part('      local address = string.format("%x", vm:GetAddress())', '    elseif not GIFT.warned') + '''
return npc end
writable=true;assert(receiver()==-1 and calls==0);old=false;writable=false;assert(receiver()==-1 and calls==0);old=true;errno=2;writable=true;assert(receiver()==9 and calls==1)
''')
print('PASS gift rejects stale reply / failed request; missing reply file is normal')
