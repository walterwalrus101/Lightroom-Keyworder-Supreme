--[[
  KeywordGroups.lua — Smart Collection hierarchy for Photo Keyworder
  ──────────────────────────────────────────────────────────────────
  This file controls how keywords are organised into groups in the
  Collections panel after a run.

  HOW TO EDIT:
  ─────────────
  1. Open this file in any plain text editor (TextEdit, Notepad, etc.)
  2. Find the group you want to change.
  3. Add or remove keywords from the list — keep them comma-separated,
     lowercase, and inside single quotes.
  4. Save the file. Changes take effect on the next plugin run.
     No need to reload the plugin or restart Lightroom.

  ADDING A NEW GROUP:
  ───────────────────
  Copy any existing group block and paste it before the 'Other' group.
  Give it a new name and fill in the keywords. Example:
      { name = 'My New Group', keywords = { 'keyword one', 'keyword two' } },

  NOTES:
  ──────
  • Any keyword that does not match any group lands in 'Other' automatically.
  • Keep 'Other' as the last entry — it is the catch-all.
  • Keyword matching is case-insensitive.
--]]

return {

    {
        name = 'People',
        keywords = {
            'man', 'woman', 'child', 'teenager', 'young adult', 'middle-aged', 'senior',
            'solo', 'duo', 'trio', 'four-piece', 'full band', 'large group', 'crowd',
        },
    },

    -- Camera and lens values are dynamic (pulled from EXIF) so the lists below
    -- are intentionally empty — keywords are matched into these groups by the
    -- smart-collection builder, not pre-declared here.  Add specific model or
    -- lens names if you want to force them into this group manually.
    {
        name = 'Camera',
        keywords = {
            -- examples (all lowercased): 'nikon z9', 'canon eos r5', 'sony a7r v'
        },
    },

    {
        name = 'Lens',
        keywords = {
            -- examples: 'nikkor z 85mm f/1.2 s', 'ef 135mm f/2l usm'
        },
    },

    {
        name = 'Orientation',
        keywords = {
            'horizontal', 'vertical', 'square',
            '1:1', '4:3', '3:4', '3:2', '2:3',
            '16:9', '9:16', '5:4', '4:5', '8:5', '5:8', '2:1', '1:2',
        },
    },

    {
        name = 'Framing',
        keywords = {
            'extreme close-up face', 'close-up face', 'headshot', 'bust shot',
            'half body', 'three-quarter body', 'full body', 'wide shot',
        },
    },

    {
        name = 'Shoot Context',
        keywords = {
            'press shot', 'album artwork', 'editorial', 'live performance',
            'backstage', 'festival', 'tour', 'promo', 'EPK',
            'headshot session', 'behind the scenes', 'music video',
            'portrait', 'environmental portrait',
        },
    },

    {
        name = 'Setting',
        keywords = {
            'indoor', 'outdoor',
            'studio', 'white cyc', 'rooftop', 'warehouse', 'industrial',
            'concert stage', 'green room', 'dressing room',
            'alley', 'urban street', 'stairwell', 'graffiti wall',
            'home', 'forest', 'beach', 'park',
            'street', 'urban', 'backstage', 'concert venue',
        },
    },

    {
        name = 'Lighting',
        keywords = {
            'natural light', 'studio light', 'mixed lighting', 'available light',
            'rim light', 'window light', 'neon light', 'single source',
            'soft light', 'harsh light', 'high-key', 'low-key',
            'dramatic', 'backlit', 'silhouette', 'golden hour',
        },
    },

    {
        name = 'Styling',
        keywords = {
            'suit', 'leather jacket', 'streetwear', 'formal', 'denim',
            'all black', 'colourful outfit', 'hat', 'cap',
            'heavy makeup', 'minimal makeup', 'costume',
            'glasses', 'sunglasses', 'tattoos',
        },
    },

    {
        name = 'Look',
        keywords = {
            'long hair', 'shaved head', 'afro', 'braids', 'dreadlocks', 'curly hair',
            'beard', 'stubble', 'clean-shaven', 'moustache',
        },
    },

    {
        name = 'Mood',
        keywords = {
            'brooding', 'intense', 'vulnerable', 'laughing', 'relaxed',
            'pensive', 'confrontational', 'connected', 'candid moment', 'confident',
            'looking at camera',
        },
    },

    {
        name = 'Instrument',
        keywords = {
            'guitar', 'electric guitar', 'acoustic guitar', 'bass guitar',
            'drums', 'piano', 'keyboard', 'synthesizer',
            'violin', 'cello', 'saxophone', 'trumpet', 'trombone',
            'microphone', 'turntables', 'flute', 'clarinet', 'harp',
        },
    },

    {
        name = 'Color',
        keywords = {
            'red', 'orange', 'yellow', 'green', 'blue', 'purple',
            'pink', 'brown', 'white', 'black', 'grey', 'gold',
            'teal', 'cyan', 'magenta',
        },
    },

    {
        name = 'Tone',
        keywords = {
            'warm tones', 'cool tones', 'muted tones', 'vibrant colours',
            'black and white', 'pastel tones', 'earthy tones',
            'neutral tones', 'golden hour', 'high contrast', 'desaturated',
        },
    },

    -- Catch-all: any keyword not matched above lands here.
    -- Do not remove or rename this entry.
    {
        name    = 'Other',
        keywords = {},
    },

}
