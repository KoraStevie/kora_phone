fx_version 'cerulean'
game 'gta5'

name 'kora_phone'
author 'Kora Team'
description 'Server-authoritative Kora phone'
version '0.0.1'

lua54 'yes'

shared_scripts {
    '@kora_lib/init.lua',
    '@kora_core/init.lua',
    '@kora_core/shared/locale.lua',
    'config/shared.lua',
    'config/handsets.lua',
    'shared/constants.lua',
    'shared/validation.lua',
    'shared/contracts.lua'
}

client_scripts {
    '@kora_theme/client/bridge.lua',
    'config/client.lua',
    'client/**/*.lua'
}

server_scripts {
    '@kora_sql/init.lua',
    'server/crypto.js',
    '@kora_sql/lib/MySQL.lua',
    'config/server.lua',
    'server/schema.lua',
    'server/integrations/*.lua',
    'server/repositories/*.lua',
    'server/services/*.lua',
    'server/rate_limits.lua',
    'server/permissions.lua',
    'server/sessions.lua',
    'server/handsets.lua',
    'server/mailboxes.lua',
    'server/phone_commerce.lua',
    'server/callbacks.lua',
    'server/modules/call_callbacks.lua',
    'server/modules/economy_callbacks.lua',
    'server/modules/media_callbacks.lua',
    'server/modules/community_callbacks.lua',
    'server/handset_callbacks.lua',
    'server/compat/qb-phone.lua',
    'server/main.lua'
}

ui_page 'web/dist/index.html'

files {
    'web/dist/index.html',
    'web/dist/assets/*',
    'web/dist/compat.js',
    'web/dist/map.jpg',
    'local-media/*'
}

dependencies {
    'kora_theme',
    'kora_lib',
    'kora_core',
    'kora_sql',
    'kora_inventory',
    'kora_voice'
}

-- Lets this resource answer as each aliased phone (client/customapps.lua) for real: many
-- custom apps gate their AddCustomApp-style call behind GetResourceState('lb-phone') (etc)
-- being 'started' before ever attempting the export, which the export-event trick alone
-- can't satisfy. `provide` makes GetResourceState and dependency resolution treat this
-- resource as if it were that one too. Don't also run the real lb-phone/sd-phone/etc
-- alongside this -- same warning sky_phone documents for the same trick: two active
-- providers of the same name race for the same registrations.
provide 'qb-phone'
provide 'lb-phone'
provide 'sd-phone'
provide '17mov_Phone'
provide 'yseries'
provide 'high-phone'

-- kora_qa: Gherkin test scenarios (converted legacy tests), see [kora]/kora_qa/README.md
qa_feature 'tests/*.feature'
