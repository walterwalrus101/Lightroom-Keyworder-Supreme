local LrView  = import 'LrView'
local LrPrefs = import 'LrPrefs'

local prefs = LrPrefs.prefsForPlugin()

local function sectionsForTopOfDialog(f, _)
    return {
        {
            title = 'Keyworder Supreme — Settings',
            f:row {
                spacing = f:label_spacing(),
                f:static_text { title = 'Google Gemini API key:', width = 180 },
                f:password_field {
                    value             = LrView.bind {
                        key   = 'geminiApiKey',
                        bind_to_object = prefs,
                    },
                    width = 300,
                },
            },
            f:row {
                spacing = f:label_spacing(),
                f:static_text { title = 'Gemini model:', width = 180 },
                f:edit_field {
                    value             = LrView.bind {
                        key   = 'geminiModel',
                        bind_to_object = prefs,
                    },
                    width = 220,
                },
                f:static_text {
                    title = '  e.g. gemini-2.5-flash',
                    font  = '<system/small>',
                },
            },
        },
    }
end

return { sectionsForTopOfDialog = sectionsForTopOfDialog }
