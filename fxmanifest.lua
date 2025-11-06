fx_version 'cerulean'
game 'gta5'

lua54 'yes'

name 'Az-Fire'
author 'Azure(TheStoicBear)'
description 'Advanced synced fire / SCBA / hose / safety system for Az-Framework'
version '1.0.0'

ui_page 'html/ui.html'

files {
    'html/ui.html',
    'html/sounds/firehouse_alarm.ogg',
    'html/sounds/scba_low.ogg',
    'html/sounds/mayday.ogg',
    'html/sounds/pass_alarm.ogg',
    'hose/contentunlocks.meta',
	'hose/loadouts.meta',
	'hose/pedpersonality.meta',
	'hose/shop_weapon.meta',
	'hose/weaponanimations.meta',
	'hose/weaponarchetypes.meta',
	'hose/weapons.meta',
}

client_scripts {
    'config.lua',
    'client.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'config.lua',
    'server.lua'
}


data_file 'WEAPONINFO_FILE' 'hose/weapons.meta'
data_file 'WEAPON_METADATA_FILE' 'hose/weaponarchetypes.meta'
data_file 'WEAPON_SHOP_INFO' 'hose/shop_weapon.meta'
data_file 'WEAPON_ANIMATIONS_FILE' 'hose/weaponanimations.meta'
data_file 'CONTENT_UNLOCKING_META_FILE' 'hose/contentunlocks.meta'
data_file 'LOADOUTS_FILE' 'hose/loadouts.meta'
data_file 'PED_PERSONALITY_FILE' 'hose/pedpersonality.meta'