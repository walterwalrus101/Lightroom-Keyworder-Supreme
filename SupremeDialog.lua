--[[
  SupremeDialog.lua — Keyworder Supreme main workflow
  ─────────────────────────────────────────────────────────────────────────────
  For every selected photo:
    1.  Erases ALL existing keywords.
    2.  Sends the photo thumbnail to Google Gemini with the chosen prompt.
    3.  Applies fresh keywords directly to the Lightroom catalogue.

  Fully automatic — no per-photo review.  Designed for full archive re-keys
  where existing keywords contain errors from previous runs or duplicate-file
  keyword bleed.

  Thumbnail architecture: one dedicated loader task requests thumbnails
  serially (callbacks are always delivered); four worker tasks only make
  HTTP API calls (parallel-safe).  Callbacks are only accepted when bytes
  is non-nil — Lightroom fires with nil first when a preview is not
  immediately cached, then fires again with the real bytes.
--]]

-- ── Lightroom SDK imports ────────────────────────────────────────────────────
local LrApplication     = import 'LrApplication'
local LrBinding         = import 'LrBinding'
local LrDialogs         = import 'LrDialogs'
local LrFileUtils       = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrHttp            = import 'LrHttp'
local LrPathUtils       = import 'LrPathUtils'
local LrPrefs           = import 'LrPrefs'
local LrProgressScope   = import 'LrProgressScope'
local LrTasks           = import 'LrTasks'
local LrView            = import 'LrView'
local JSON              = require 'JSON'

local KeywordGroups = dofile(LrPathUtils.child(_PLUGIN.path, 'KeywordGroups.lua'))

-- ── Plugin preferences ───────────────────────────────────────────────────────
local prefs = LrPrefs.prefsForPlugin()

-- ── Constants ────────────────────────────────────────────────────────────────
local GEMINI_MODEL_DEFAULT = 'gemini-2.5-flash'
local THUMB_SIZE           = 512
local COST_PER_IMAGE       = 0.00026   -- gemini-2.5-flash, thinking disabled, 512px thumbnail
local RATE_LIMIT_RPM       = 2000
local NUM_WORKERS          = 4
local PHOTOS_PER_MIN_EST   = 150   -- conservative ETA estimate

-- ── Rate limiter ─────────────────────────────────────────────────────────────
local _rateCallTimes = {}
local _rateMu        = false

local function waitForRateLimit()
    while _rateMu do LrTasks.yield() end
    _rateMu = true
    local now   = os.time()
    local fresh = {}
    for _, t in ipairs(_rateCallTimes) do
        if now - t < 60 then fresh[#fresh+1] = t end
    end
    _rateCallTimes = fresh
    local sleepSecs = 0
    if #_rateCallTimes >= RATE_LIMIT_RPM - 1 then
        local waitSecs = 61 - (now - _rateCallTimes[1])
        if waitSecs > 0 then sleepSecs = waitSecs end
    end
    _rateCallTimes[#_rateCallTimes+1] = os.time()
    _rateMu = false
    if sleepSecs > 0 then LrTasks.sleep(sleepSecs) end
end

-- ── Base64 encoder ───────────────────────────────────────────────────────────
local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local function base64Encode(bytes)
    local out = {}
    for i = 1, #bytes, 3 do
        local a, b, c = bytes:byte(i, i+2)
        b = b or 0; c = c or 0
        local v = a*65536 + b*256 + c
        out[#out+1] = B64:sub(math.floor(v/262144)%64+1, math.floor(v/262144)%64+1)
        out[#out+1] = B64:sub(math.floor(v/4096)%64+1,   math.floor(v/4096)%64+1)
        out[#out+1] = (#bytes >= i+1) and B64:sub(math.floor(v/64)%64+1, math.floor(v/64)%64+1) or '='
        out[#out+1] = (#bytes >= i+2) and B64:sub(v%64+1, v%64+1) or '='
    end
    return table.concat(out)
end

-- ── Gemini prompts ────────────────────────────────────────────────────────────
local PROMPTS = {}

PROMPTS['auto'] = [[
You are a photo library assistant. First decide which single category best describes this photo, then output keywords tailored to that category.

Output EXACTLY 7 lines — nothing else before or after:

CATEGORY: [portrait | landscape | candid]
LOCATION: [indoor or outdoor]
LIGHTING: [natural light | studio light | mixed lighting]
COLOR: [single most dominant colour across the ENTIRE image — background, clothing, and all elements combined — one word from: red orange yellow green blue purple pink brown white black grey gold teal]
TONE: [overall palette — one phrase from: warm tones | cool tones | muted tones | vibrant colours | black and white | pastel tones | earthy tones | neutral tones | golden hour | high contrast]
CAPTION: [one vivid sentence describing subject, setting, lighting and mood]
KEYWORDS: [15 to 20 comma-separated keywords — do NOT repeat values already given in CATEGORY, LOCATION, LIGHTING, COLOR or TONE above. No colour words. Use the list for the CATEGORY you chose:]

  portrait — who (man, woman, child, teenager, young adult, middle-aged, senior), group size (solo, duo, trio, four-piece, full band, large group), look (long hair, shaved head, afro, braids, beard, stubble, glasses, sunglasses, tattoos), styling (suit, leather jacket, streetwear, formal, denim, all black, colourful outfit, hat, heavy makeup, costume), instrument if visible (guitar, bass, drums, piano, keyboard, saxophone, trumpet, microphone), framing REQUIRED pick exactly one (extreme close-up face, close-up face, headshot, bust shot, half body, three-quarter body, full body, wide shot) where: extreme close-up face=only part of face; close-up face=full face fills frame; headshot=face+shoulders to collarbone; bust shot=head to mid-chest; half body=head to waist; three-quarter body=head to mid-thigh; full body=entire person head to toe; wide shot=person small in frame, shoot context (press shot, album artwork, editorial, live performance, backstage, festival, EPK, music video, headshot session, behind the scenes), setting (studio, white cyc, rooftop, warehouse, industrial, concert stage, alley, urban street, stairwell, home, forest, beach, graffiti wall), lighting quality (rim light, window light, neon light, single source, high-key, low-key, dramatic, soft light, backlit, silhouette, golden hour), mood (brooding, intense, vulnerable, laughing, relaxed, pensive, confrontational, connected, candid moment, confident), eye contact (if eyes clearly aimed at lens include "looking at camera")

  landscape — cover: scene (mountain, valley, canyon, cliff, forest, woodland, meadow, coast, beach, ocean, sea, lake, river, waterfall, desert, glacier, arctic, island), sky & weather (clear sky, dramatic clouds, overcast, storm, fog, mist, rain, snow, golden hour, blue hour, sunset, sunrise, rainbow, aurora, milky way, night sky), time of day (dawn, morning, midday, afternoon, dusk, night), season (spring, summer, autumn, winter), vegetation (trees, wildflowers, grass, reeds, tropical, deciduous, coniferous, bare trees), water (calm water, rough sea, crashing waves, reflection, waterfall, rapids, still lake, long exposure), composition (leading lines, foreground interest, panoramic, layered landscape, silhouette, wide angle, aerial, rule of thirds), mood (peaceful, dramatic, moody, serene, desolate, wild, majestic, vast, ethereal)

  candid — cover: who (man, woman, child, teenager, elderly, couple, family, group, crowd), action (walking, running, talking, laughing, eating, working, playing, dancing, sitting, shopping, performing, embracing), emotion (joy, laughter, sadness, surprise, concentration, tenderness, anger, excitement, contemplation, intimacy), setting (street, market, cafe, park, festival, concert, sporting event, workplace, restaurant, airport, playground), style (reportage, documentary, street photography, photojournalism, travel photography, humanist photography), composition (decisive moment, motion blur, freeze action, wide establishing shot, tight close-up, environmental context, layered depth), mood (lively, quiet, intimate, chaotic, nostalgic, gritty, joyful, tense, peaceful, melancholic)

Example output for a musician portrait:
CATEGORY: portrait
LOCATION: indoor
LIGHTING: studio light
COLOR: black
TONE: high contrast
CAPTION: A bearded middle-aged musician rim-lit in a dark studio, headshot with a brooding expression.
KEYWORDS: portrait, man, solo, beard, long hair, leather jacket, headshot, middle-aged, low-key, rim light, bokeh background, shallow depth of field, brooding, press shot, studio, serious

Example output for a mountain sunset:
CATEGORY: landscape
LOCATION: outdoor
LIGHTING: natural light
COLOR: gold
TONE: golden hour
CAPTION: Snow-capped mountain peaks silhouetted against a golden-hour sky with layered forest below.
KEYWORDS: mountain, alpine, peaks, dramatic clouds, sunset, golden hour, wide angle, layered landscape, silhouette, vast, majestic, coniferous trees, valley, panoramic, rule of thirds, serene, highland

Example output for a street market:
CATEGORY: candid
LOCATION: outdoor
LIGHTING: natural light
COLOR: orange
TONE: warm tones
CAPTION: A bustling outdoor street market with vendors and shoppers in warm afternoon light.
KEYWORDS: street market, crowd, vendors, shopping, bustling, lively, documentary, wide shot, environmental context, market stalls, urban, candid, spontaneous, travel photography, chaotic, street photography
]]

PROMPTS['portrait'] = [[
You are a photo library assistant specialising in portrait and music photography. Look at the image and output EXACTLY 6 lines in this format — nothing else before or after:

LOCATION: [indoor or outdoor]
LIGHTING: [natural light | studio light | mixed lighting]
COLOR: [the single most dominant colour across the entire image — background, clothing, and all elements combined — one word from: red orange yellow green blue purple pink brown white black grey gold teal]
TONE: [overall palette — one phrase from: warm tones | cool tones | muted tones | vibrant colours | black and white | pastel tones | earthy tones | neutral tones | golden hour | high contrast]
CAPTION: [one vivid sentence describing subject, setting, lighting and mood]
KEYWORDS: [15 to 20 comma-separated keywords — do NOT repeat values already given in LOCATION, LIGHTING, COLOR or TONE above. No colour words. Cover as many of these as apply:]
- Who: man, woman, solo, duo, trio, group, band, crowd, child, teenager, young adult, middle-aged, senior
- Look: long hair, shaved head, afro, braids, dreadlocks, curly hair, beard, stubble, clean-shaven, moustache, glasses, sunglasses, hat, cap, bandana, earrings, tattoos, suit, casual, streetwear, leather jacket, denim jacket, formal
- Instrument: guitar, bass, drums, piano, keyboard, violin, saxophone, trumpet, microphone, turntables (only if visible)
- Framing (REQUIRED — pick exactly one): extreme close-up face, close-up face, headshot, bust shot, half body, three-quarter body, full body, wide shot
- Shot type: portrait, environmental portrait, press shot, album artwork, editorial, live performance, backstage, behind the scenes
- Angle & composition: eye level, low angle, high angle, bird's eye, centred, rule of thirds, negative space, symmetrical, bokeh background, shallow depth of field
- Lighting quality: high-key, low-key, dramatic, soft light, harsh light, rim light, backlit, silhouette
- Setting: studio, rooftop, alley, concert venue, backstage, home, street, warehouse, park, graffiti wall, urban, forest, beach
- Mood: serious, intense, relaxed, joyful, candid, laughing, brooding, confident, vulnerable, pensive, dramatic
- Eye contact: if the subject's eyes are clearly and directly aimed at the camera lens, add "looking at camera" as one of the keywords

Framing guide:
  extreme close-up face = only part of the face fills the frame (eyes, lips, etc.)
  close-up face         = full face fills most of the frame, little or no neck/shoulders visible
  headshot              = face and neck/shoulders, roughly from collar-bone up
  bust shot             = head down to mid-chest
  half body             = head down to waist
  three-quarter body    = head down to mid-thigh or knee
  full body             = entire person visible head to toe
  wide shot             = person occupies a small part of the frame; setting dominates

Example output for a musician portrait:
LOCATION: indoor
LIGHTING: studio light
COLOR: black
TONE: high contrast
CAPTION: A bearded middle-aged musician rim-lit in a dark studio, headshot portrait with a brooding serious expression.
KEYWORDS: portrait, man, solo, beard, long hair, leather jacket, headshot, middle-aged, low-key, rim light, bokeh background, shallow depth of field, brooding, press shot, studio, serious

Example output for a band shot:
LOCATION: outdoor
LIGHTING: natural light
COLOR: grey
TONE: muted tones
CAPTION: Four men in casual streetwear standing full body in a grey urban alley, soft natural light, editorial feel.
KEYWORDS: group, band, four people, men, street, urban, alley, graffiti wall, casual, full body, wide shot, candid, confident, eye level, soft light, editorial
]]

PROMPTS['landscape'] = [[
You are a photo library assistant specialising in landscape and nature photography. Look at the image and output EXACTLY 6 lines in this format — nothing else before or after:

LOCATION: [indoor or outdoor]
LIGHTING: [natural light | studio light | mixed lighting]
COLOR: [the single most dominant colour — one word from: red orange yellow green blue purple pink brown white black grey gold teal]
TONE: [overall palette — one phrase from: warm tones | cool tones | muted tones | vibrant colours | black and white | pastel tones | earthy tones | neutral tones | golden hour | high contrast]
CAPTION: [one vivid sentence describing subject, setting, lighting and mood]
KEYWORDS: [15 to 20 comma-separated keywords — do NOT repeat values already given in LOCATION, LIGHTING, COLOR or TONE above. No colour words. Cover as many of these as apply:]
- Scene: mountain, valley, canyon, cliff, rock formation, volcano, glacier, arctic, tundra, forest, woodland, meadow, field, farmland, countryside, coast, beach, ocean, sea, lake, river, stream, waterfall, wetland, swamp, desert, sand dunes, cave, island, peninsula
- Sky & weather: clear sky, dramatic clouds, overcast, storm, fog, mist, rain, snow, hail, wind, golden hour, blue hour, sunset, sunrise, rainbow, lightning, aurora borealis, star trails, milky way, night sky, partial clouds
- Time of day: dawn, morning, midday, afternoon, dusk, night
- Season: spring, summer, autumn, winter
- Vegetation: dense forest, sparse trees, wildflowers, tall grass, reeds, moss, lichen, cactus, palm trees, tropical vegetation, deciduous trees, coniferous trees, bare branches, autumn leaves
- Water: calm water, rough sea, crashing waves, ocean spray, mirror reflection, rushing waterfall, rapids, still lake, winding river, ice, frozen lake, snow field
- Composition: leading lines, foreground interest, reflection, panoramic view, layered landscape, silhouette, long exposure, wide angle, aerial view, symmetrical, rule of thirds, negative space
- Mood: peaceful, dramatic, moody, serene, desolate, wild, majestic, intimate, vast, threatening, sublime, ethereal
- Geography (if clear): alpine, mediterranean, tropical, nordic, arid, temperate, coastal, highland, lowland, canyon lands, steppe

Example output for a mountain sunset:
LOCATION: outdoor
LIGHTING: natural light
COLOR: gold
TONE: golden hour
CAPTION: Snow-capped mountain peaks silhouetted against a golden-hour sky, layered coniferous forest stretching into the valley below.
KEYWORDS: mountain, alpine, peaks, snow-capped, dramatic clouds, sunset, golden hour, wide angle, layered landscape, silhouette, vast, majestic, coniferous trees, valley, panoramic view, rule of thirds, serene, highland

Example output for a coastal scene:
LOCATION: outdoor
LIGHTING: natural light
COLOR: teal
TONE: cool tones
CAPTION: Rocky coastline battered by crashing waves under a dramatic overcast sky, long-exposure mist softening the foreground rocks.
KEYWORDS: coast, rocky coastline, ocean, waves, crashing waves, cliff, dramatic clouds, long exposure, leading lines, moody, wild, wide angle, foreground interest, misty, overcast, temperate, seascape
]]

PROMPTS['candid'] = [[
You are a photo library assistant specialising in candid, documentary and street photography. Look at the image and output EXACTLY 6 lines in this format — nothing else before or after:

LOCATION: [indoor or outdoor]
LIGHTING: [natural light | studio light | mixed lighting]
COLOR: [the single most dominant colour — one word from: red orange yellow green blue purple pink brown white black grey gold teal]
TONE: [overall palette — one phrase from: warm tones | cool tones | muted tones | vibrant colours | black and white | pastel tones | earthy tones | neutral tones | golden hour | high contrast]
CAPTION: [one vivid sentence describing subject, setting, lighting and mood]
KEYWORDS: [15 to 20 comma-separated keywords — do NOT repeat values already given in LOCATION, LIGHTING, COLOR or TONE above. No colour words. Cover as many of these as apply:]
- Who: man, woman, child, teenager, elderly person, couple, family, group, crowd, solo subject
- What they are doing: walking, running, talking, laughing, eating, drinking, working, playing, dancing, sitting, standing, watching, reading, shopping, cycling, protesting, performing, embracing, arguing, resting
- Emotion & expression: joy, laughter, sadness, surprise, concentration, tenderness, anger, excitement, contemplation, intimacy, boredom, wonder, grief, pride
- Setting: street, market, cafe, park, public transport, festival, concert, sporting event, protest, workplace, home, school, beach, restaurant, bar, airport, place of worship, tourist site, playground
- Style: reportage, documentary, street photography, photojournalism, travel photography, social documentary, humanist photography
- Action quality: decisive moment, peak action, fleeting expression, chance encounter, spontaneous interaction, unposed, candid, behind the scenes
- Composition: environmental context, motion blur, freeze action, wide establishing shot, tight close-up, over the shoulder, layered depth, framed subject
- Urban detail: architecture, graffiti, signage, vehicles, crowds, storefronts, alley, public space, market stalls, street art
- Mood: lively, quiet, intimate, chaotic, nostalgic, gritty, joyful, tense, peaceful, melancholic, hopeful

Example output for a street market scene:
LOCATION: outdoor
LIGHTING: natural light
COLOR: orange
TONE: warm tones
CAPTION: A bustling outdoor street market with vendors and shoppers moving through stalls bathed in warm afternoon light.
KEYWORDS: street market, crowd, vendors, shopping, people, bustling, lively, documentary, photojournalism, wide shot, environmental context, market stalls, urban, layered depth, candid, spontaneous interaction, travel photography, chaotic, street photography

Example output for an intimate portrait moment:
LOCATION: indoor
LIGHTING: natural light
COLOR: grey
TONE: muted tones
CAPTION: An elderly couple sitting quietly together at home, bathed in soft window light, their closeness tender and contemplative.
KEYWORDS: couple, elderly, sitting, tenderness, intimacy, candid, quiet, contemplation, home, window light, tight close-up, humanist photography, unposed, decisive moment, peaceful, social documentary, storytelling
]]

-- ── Gemini API call ──────────────────────────────────────────────────────────
local function callGeminiAPI(apiKey, imageBytes, prompt)
    if not imageBytes or #imageBytes == 0 then return nil, 'No image data' end
    local b64           = base64Encode(imageBytes)
    local escapedPrompt = prompt:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n')
    local body = table.concat({
        '{"contents":[{"parts":[',
        '{"text":"', escapedPrompt, '"},',
        '{"inline_data":{"mime_type":"image/jpeg","data":"', b64, '"}}',
        ']}],"generationConfig":{"temperature":0.1,"maxOutputTokens":2048,"thinkingConfig":{"thinkingBudget":0}}}',
    })
    local url = 'https://generativelanguage.googleapis.com/v1beta/models/'
             .. (prefs.geminiModel or GEMINI_MODEL_DEFAULT)
             .. ':generateContent?key=' .. apiKey
    local response, headers = LrHttp.post(
        url, body, {{ field='Content-Type', value='application/json' }}
    )
    if not response then return nil, 'Network request failed' end
    local status = headers and headers.status or 0
    if status ~= 200 then
        local dec    = JSON.decode(response)
        local errMsg = dec and dec.error and dec.error.message or ('HTTP '..status)
        return nil, 'Gemini error: '..errMsg
    end
    return response, nil
end

-- ── Parse Gemini response → keyword list + caption ───────────────────────────
local COLOR_WORDS = {
    red=true,orange=true,yellow=true,green=true,blue=true,purple=true,
    pink=true,brown=true,white=true,black=true,grey=true,gray=true,
    gold=true,golden=true,teal=true,cyan=true,magenta=true,silver=true,
    beige=true,ivory=true,maroon=true,navy=true,olive=true,coral=true,
    turquoise=true,violet=true,indigo=true,crimson=true,neon=true,
    amber=true,scarlet=true,azure=true,lavender=true,khaki=true,
    lime=true,mint=true,rose=true,peach=true,sand=true,rust=true,
    burgundy=true,mauve=true,taupe=true,charcoal=true,ochre=true,
    terracotta=true,umber=true,sienna=true,
    tone=true,tones=true,colour=true,color=true,palette=true,hue=true,
    hues=true,warm=true,cool=true,vibrant=true,muted=true,
    saturated=true,desaturated=true,monochrome=true,pastel=true,
    earthy=true,neutral=true,colourful=true,colorful=true,
}
local function isColorWord(token)
    for word in token:gmatch('[%a]+') do
        if COLOR_WORDS[word] then return true end
    end
    return false
end

local NOISE = {
    json=true,keyword=true,keywords=true,name=true,score=true,
    array=true,['null']=true,['true']=true,['false']=true,
    example=true,output=true,format=true,list=true,here=true,
    are=true,the=true,['and']=true,['or']=true,of=true,a=true,
    location=true,lighting=true,color=true,colour=true,tone=true,
}

local LABELS = {
    category=true,location=true,lighting=true,
    color=true,colour=true,tone=true,caption=true,keywords=true,
}
local function isLabel(s)
    local lbl = s:match('^([%a]+)%s*:')
    return lbl and LABELS[lbl] or false
end

local function parseKeywords(jsonStr)
    local decoded = JSON.decode(jsonStr)
    if not decoded then return nil, nil, 'Could not parse API response' end
    if decoded.error then return nil, nil, decoded.error.message or 'API error' end

    local candidates = decoded.candidates
    if type(candidates) ~= 'table' or not candidates[1] then
        local block = decoded.promptFeedback and decoded.promptFeedback.blockReason
        if block then return nil, nil, 'skipped:safety:'..block end
        return nil, nil, 'No candidates in response'
    end
    local fr = candidates[1].finishReason
    if fr == 'SAFETY' or fr == 'PROHIBITED_CONTENT' then
        return nil, nil, 'skipped:safety:'..fr
    end
    local parts = candidates[1].content and candidates[1].content.parts
    if type(parts) ~= 'table' or not parts[1] then return nil, nil, 'No content in response' end

    local text = parts[1].text or ''
    text = text:match('```[%w]*%s*(.-)%s*```') or text
    text = text:match('^%s*(.-)%s*$')

    local function clean(s)
        if not s then return nil end
        return s:match('^%s*(.-)%s*$'):lower()
    end

    local catRaw  = text:match('[Cc][Aa][Tt][Ee][Gg][Oo][Rr][Yy]%s*:%s*([^\n]+)')
    local loc     = text:match('[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]%s*:%s*([^\n]+)')
    local lit     = text:match('[Ll][Ii][Gg][Hh][Tt][Ii][Nn][Gg]%s*:%s*([^\n]+)')
    local col     = text:match('[Cc][Oo][Ll][Oo][Uu]?[Rr]%s*:%s*([^\n]+)')
    local ton     = text:match('[Tt][Oo][Nn][Ee]%s*:%s*([^\n]+)')
    local capRaw  = text:match('[Cc][Aa][Pp][Tt][Ii][Oo][Nn]%s*:%s*([^\n]+)')
    local kwLine  = text:match('[Kk][Ee][Yy][Ww][Oo][Rr][Dd][Ss]%s*:%s*([^\n]+)')
    if not kwLine or kwLine:match('^%s*$') then
        kwLine = text:match('[Kk][Ee][Yy][Ww][Oo][Rr][Dd][Ss]%s*:?%s*\n%s*([^\n]+)')
    end

    catRaw = clean(catRaw)
    loc    = clean(loc)
    lit    = clean(lit)
    col    = clean(col)
    ton    = clean(ton)
    local caption = capRaw and capRaw:match('^%s*(.-)%s*$') or nil

    local category = nil
    if catRaw then
        if     catRaw:find('portrait')   then category = 'portrait'
        elseif catRaw:find('landscape') or catRaw:find('nature') then category = 'landscape'
        elseif catRaw:find('candid')    or catRaw:find('documentary') then category = 'candid'
        end
    end

    if loc then loc = loc:find('out') and 'outdoor' or 'indoor' end
    if lit then
        if     lit:find('studio') then lit = 'studio light'
        elseif lit:find('mix')    then lit = 'mixed lighting'
        else                           lit = 'natural light'
        end
    end
    if col then
        col = col:match('^([%a]+)') or col
        col = col:match('^[%p%s]*(.-)[%p%s]*$') or col
        if col == '' then col = nil end
    end
    if ton then
        ton = ton:match('^[%p%s]*(.-)[%p%s]*$') or ton
        if ton == '' then ton = nil end
    end

    local keywords = {}
    local seen     = {}

    local function addFixed(w)
        if w and not seen[w] then
            seen[w] = true
            keywords[#keywords+1] = { name=w, score=1.0 }
        end
    end
    addFixed(category)
    addFixed(loc or 'indoor')
    addFixed(lit or 'natural light')
    addFixed(col or 'neutral')
    addFixed(ton or 'neutral tones')

    local raw = (kwLine or text):gsub('[%[%]{}"\'\\]',''):gsub('%d+%.?%d*','')
    local pos = 0
    for token in raw:gmatch('[^,\n]+') do
        local w = token:match('^%s*(.-)%s*$'):lower()
        w = w:match('^[%p%s]*(.-)[%p%s]*$') or w
        if w ~= '' and #w >= 2 and not NOISE[w] and not seen[w]
                and not isColorWord(w) and not isLabel(w) then
            seen[w] = true
            pos = pos + 1
            keywords[#keywords+1] = { name=w, score=math.max(0.60, 0.95-(pos-1)*0.018) }
        end
    end

    return keywords, caption, nil
end

-- ── Orientation & aspect ratio ───────────────────────────────────────────────
local function getOrientationAndRatio(photo)
    local w = photo:getRawMetadata('width')  or 0
    local h = photo:getRawMetadata('height') or 0
    if w == 0 or h == 0 then return nil, nil end
    local o = photo:getRawMetadata('orientation') or ''
    if o == 'BC' or o == 'DA' then w, h = h, w end
    local orientation = (w > h) and 'horizontal' or (h > w) and 'vertical' or 'square'
    local f = w/h; if f < 1 then f = 1/f end
    local RATIOS = {
        {1.000,'1:1'},{1.250,'5:4'},{1.333,'4:3'},{1.500,'3:2'},
        {1.600,'8:5'},{1.778,'16:9'},{2.000,'2:1'},
    }
    local best, bestDist = '3:2', 999
    for _, r in ipairs(RATIOS) do
        local d = math.abs(f - r[1])
        if d < bestDist then bestDist=d; best=r[2] end
    end
    if h > w then best = best:gsub('(%d+):(%d+)', function(a,b) return b..':'..a end) end
    return orientation, best
end

-- ── EXIF helper ──────────────────────────────────────────────────────────────
local function cleanMeta(s)
    if type(s) ~= 'string' then return nil end
    s = s:match('^%s*(.-)%s*$')
    return (s ~= '') and s:lower() or nil
end

-- ── Resume state ─────────────────────────────────────────────────────────────
-- Saved to disk after the scan phase so a crash during apply can be recovered.
-- Deleted automatically on successful completion.
local RESUME_FILE = LrPathUtils.child(_PLUGIN.path, 'supreme_resume.lua')

local function saveResumeState(results, style)
    local f, ioErr = io.open(RESUME_FILE, 'w')
    if not f then
        LrDialogs.message('Keyworder Supreme — Resume Warning',
            'Could not save resume file:\n' .. (ioErr or 'unknown error') .. '\n\n'
         .. 'If the run is interrupted during the apply phase you will need to re-scan.',
            'warning')
        return
    end
    f:write('-- Keyworder Supreme resume state — do not edit manually\n')
    f:write(string.format('local style = %q\n', style or 'auto'))
    f:write('return style, {\n')
    for _, r in ipairs(results) do
        f:write(string.format('  { uuid=%q, name=%q, err=%s, caption=%s, keywords={',
            r.uuid    or '',
            r.name    or '',
            r.err     and string.format('%q', r.err)     or 'nil',
            r.caption and string.format('%q', r.caption) or 'nil'
        ))
        for j, kw in ipairs(r.keywords or {}) do
            f:write(string.format('%q', kw.name))
            if j < #r.keywords then f:write(',') end
        end
        f:write(' } },\n')
    end
    f:write('}\n')
    f:close()
end

local function deleteResumeState()
    LrFileUtils.delete(RESUME_FILE)
end

-- ── Main entry point ──────────────────────────────────────────────────────────
local catalog = LrApplication.activeCatalog()

LrFunctionContext.callWithContext('KeyworederSupreme', function(_ctx)
    LrTasks.startAsyncTask(function()

        -- ── API key ────────────────────────────────────────────────────────────
        local apiKey = prefs.geminiApiKey
        if not apiKey or apiKey == '' then
            LrDialogs.message('Keyworder Supreme',
                'No Gemini API key found.\n\n'
             .. 'Add your key via File → Plugin Manager → Keyworder Supreme → Settings.',
                'warning')
            return
        end

        -- ── Ensure batch-tracking smart collections exist ─────────────────────
        -- Created once here so they are available before the first run and
        -- stay up to date as ks-done is stamped on each processed photo.
        catalog:withWriteAccessDo('Keyworder Supreme: create batch collections', function()
            local batchSet = catalog:createCollectionSet('Keyworder Supreme — Batches', nil, true)
            if batchSet then
                -- Photos Supreme has already processed this session or previously
                catalog:createSmartCollection('Already Processed', {
                    combine = 'intersect',
                    { criteria='keywords', operation='words', value='ks-done', value2='' },
                }, batchSet, true)
                -- Photos not yet touched by Supreme — select these for the next batch
                catalog:createSmartCollection('Not Yet Processed', {
                    combine = 'intersect',
                    { criteria='keywords', operation='nwords', value='ks-done', value2='' },
                }, batchSet, true)
            end
        end)

        -- ── Selected photos ────────────────────────────────────────────────────
        local allPhotos = catalog:getTargetPhotos()
        if not allPhotos or #allPhotos == 0 then
            LrDialogs.message('Keyworder Supreme',
                'No photos selected. Select photos in the Library grid first.', 'info')
            return
        end

        local photos, videoCount = {}, 0
        for _, photo in ipairs(allPhotos) do
            if photo:getRawMetadata('isVideo') then
                videoCount = videoCount + 1
            else
                photos[#photos+1] = photo
            end
        end
        if #photos == 0 then
            LrDialogs.message('Keyworder Supreme',
                'All selected files are videos — nothing to process.', 'info')
            return
        end

        -- ── Confirmation dialog ────────────────────────────────────────────────
        local estMins    = math.ceil(#photos / PHOTOS_PER_MIN_EST)
        local estTimeStr = estMins >= 120
            and string.format('~%.1f hours', estMins/60)
            or  estMins >= 60
                and string.format('~1 hr %d min', estMins-60)
                or  string.format('~%d minutes', estMins)

        local f           = LrView.osFactory()
        local dialogOk, pickedStyle, writeXmp, createSmartColls = LrFunctionContext.callWithContext('supreme_dlg',
            function(dlgCtx)
                local props  = LrBinding.makePropertyTable(dlgCtx)
                props.style            = prefs.lastStyle or 'auto'
                props.writeXmp         = prefs.writeXmp ~= false        -- default true
                props.smartCollections = prefs.smartCollections ~= false -- default true

                local dr = LrDialogs.presentModalDialog {
                    title    = 'Keyworder Supreme',
                    contents = f:column {
                        bind_to_object = props,
                        spacing        = f:dialog_spacing(),
                        f:static_text {
                            title = string.format(
                                'WARNING: This will ERASE all existing keywords on\n'
                             .. '%d photo%s and replace them with fresh Gemini keywords.\n\n'
                             .. 'There is no undo. Ensure you have a catalogue backup.',
                                #photos, #photos == 1 and '' or 's'
                            ),
                            font           = '<system/bold>',
                            width_in_chars = 52,
                            height_in_lines = 4,
                        },
                        f:separator { fill_horizontal = 1 },
                        f:static_text { title='Photography style:', font='<system/bold>' },
                        f:row { f:radio_button { title='Auto-detect  (portrait / landscape / candid per photo)',
                            value=LrView.bind('style'), checked_value='auto'      } },
                        f:row { f:radio_button { title='Portrait & Music',
                            value=LrView.bind('style'), checked_value='portrait'  } },
                        f:row { f:radio_button { title='Landscape & Nature',
                            value=LrView.bind('style'), checked_value='landscape' } },
                        f:row { f:radio_button { title='Candid & Documentary',
                            value=LrView.bind('style'), checked_value='candid'    } },
                        f:separator { fill_horizontal = 1 },
                        f:row {
                            f:checkbox {
                                value = LrView.bind('writeXmp'),
                                title = 'Also write keywords to XMP sidecars / file metadata',
                                font  = '<system>',
                            },
                        },
                        f:static_text {
                            title = 'Overwrites existing XMP keywords on disk. Recommended when a\n'
                                 .. 'previous tool already wrote keywords to XMP.',
                            font  = '<system/small>',
                        },
                        f:row {
                            f:checkbox {
                                value = LrView.bind('smartCollections'),
                                title = 'Create smart collections for each keyword',
                                font  = '<system>',
                            },
                        },
                        f:static_text {
                            title = 'Organised into a "Keyworder Supreme" set in your Collections panel.\n'
                                 .. 'New keywords get new collections; existing ones are updated automatically.',
                            font  = '<system/small>',
                        },
                        f:separator { fill_horizontal = 1 },
                        f:static_text {
                            title = string.format(
                                'Photos: %d%s\nEst. cost: $%.4f     Est. time: %s',
                                #photos,
                                videoCount > 0
                                    and string.format('  (%d video%s skipped)',
                                        videoCount, videoCount==1 and '' or 's') or '',
                                #photos * COST_PER_IMAGE, estTimeStr
                            ),
                            font = '<system/small>',
                        },
                    },
                    actionVerb = 'Erase & Re-Keyword',
                }
                return dr == 'ok', props.style, props.writeXmp, props.smartCollections
            end)

        if not dialogOk then return end
        prefs.lastStyle        = pickedStyle
        prefs.writeXmp         = writeXmp
        prefs.smartCollections = createSmartColls

        local activePrompt = PROMPTS[pickedStyle] or PROMPTS['auto']

        -- ── Resume check ───────────────────────────────────────────────────────
        local scanResults = {}
        local skipScan    = false

        local resumeHandle = io.open(RESUME_FILE, 'r')
        if resumeHandle then
            resumeHandle:close()
            local choice = LrDialogs.confirm(
                'Keyworder Supreme — Resume Previous Run?',
                'A previous run was interrupted before it finished writing keywords.\n\n'
             .. 'Resume to skip the API scan and go straight to applying keywords\n'
             .. 'using the saved results (free — no extra API calls).\n\n'
             .. 'Start Fresh to discard the saved results and re-scan all photos.',
                'Resume', 'Start Fresh')
            if choice == 'ok' then
                -- Load saved results and match photos back by UUID
                local savedStyle, savedResults = dofile(RESUME_FILE)
                local photoByUuid = {}
                for _, photo in ipairs(photos) do
                    local u = photo:getRawMetadata('uuid') or ''
                    if u ~= '' then photoByUuid[u] = photo end
                end
                for _, r in ipairs(savedResults or {}) do
                    local photo = photoByUuid[r.uuid]
                    if photo then
                        local keywords = {}
                        for _, kwName in ipairs(r.keywords or {}) do
                            keywords[#keywords+1] = { name=kwName, score=1.0 }
                        end
                        scanResults[#scanResults+1] = {
                            photo=photo, uuid=r.uuid, name=r.name,
                            keywords=keywords, caption=r.caption, err=r.err,
                        }
                    end
                end
                -- Use the style from the saved run
                if savedStyle and PROMPTS[savedStyle] then
                    activePrompt = PROMPTS[savedStyle]
                end
                skipScan = true
            else
                deleteResumeState()
            end
        end

        -- Declared outside scan block so summary can always reference them
        local workerErrors   = {}
        local estimatedSpend = 0.0

        if not skipScan then

        -- ── Scan: dedicated loader + 4 API workers ────────────────────────────
        local progress = LrProgressScope {
            title = string.format('Re-keywording %d photo%s…',
                #photos, #photos == 1 and '' or 's'),
        }

        -- Loader fills thumbData[i]; workers read and nil-out each entry.
        local thumbData   = {}
        local thumbLoaded = 0
        local loaderDone  = false

        local queuePos       = 0
        local queueMu        = false
        local workersDone    = 0
        local doneCount      = 0

        -- ── Thumbnail loader task (one caller → callbacks always delivered) ────
        LrTasks.startAsyncTask(function()
            for i, photo in ipairs(photos) do
                if progress:isCanceled() then break end

                local name        = photo:getFormattedMetadata('fileName') or ('Photo '..i)
                local imgData, ready = nil, false

                -- Lightroom fires callback with nil when preview isn't immediately
                -- cached, then fires again with real bytes. Only accept non-nil.
                photo:requestJpegThumbnail(THUMB_SIZE, THUMB_SIZE, function(bytes)
                    if bytes then imgData = bytes; ready = true end
                end)
                local iters = 0
                while not ready and iters < 100 do   -- 10 s timeout
                    LrTasks.sleep(0.1)
                    iters = iters + 1
                end

                thumbData[i] = { photo=photo, name=name, imgData=imgData }
                thumbLoaded  = i
            end
            loaderDone = true
        end)

        -- ── Worker tasks (API calls only) ─────────────────────────────────────
        local function supremeWorker()
            while true do
                while queueMu do LrTasks.sleep(0.01) end
                queueMu  = true
                queuePos = queuePos + 1
                local myIdx = queuePos
                queueMu  = false

                if myIdx > #photos then break end

                -- Wait for loader to fill this slot
                while myIdx > thumbLoaded do
                    if progress:isCanceled() or loaderDone then break end
                    LrTasks.sleep(0.05)
                end

                local item = thumbData[myIdx]
                thumbData[myIdx] = nil   -- free memory after claiming
                if not item then break end
                if progress:isCanceled() then break end

                local photo   = item.photo
                local name    = item.name
                local imgData = item.imgData

                local uuid = photo:getRawMetadata('uuid') or ''

                if not imgData then
                    table.insert(scanResults, {
                        photo=photo, uuid=uuid, name=name, keywords={}, caption=nil,
                        err='Could not load image thumbnail',
                    })
                else
                    local responseJson, apiErr
                    for attempt = 1, 3 do
                        waitForRateLimit()
                        responseJson, apiErr = callGeminiAPI(apiKey, imgData, activePrompt)
                        if responseJson then break end
                        local transient = apiErr and (
                            apiErr:find('429') or apiErr:find('rate') or
                            apiErr:find('quota') or apiErr:find('Network') or
                            apiErr:find('500')  or apiErr:find('503')
                        )
                        if not transient or attempt == 3 then break end
                        LrTasks.sleep(2 ^ attempt)
                    end

                    if apiErr then
                        table.insert(scanResults, {
                            photo=photo, name=name, keywords={}, caption=nil, err=apiErr,
                        })
                    else
                        estimatedSpend = estimatedSpend + COST_PER_IMAGE
                        local keywords, caption, parseErr = parseKeywords(responseJson)
                        keywords = keywords or {}

                        -- Sparse retry: if fewer than 5 AI keywords, retry once
                        -- with a focused category-specific prompt instead of the
                        -- same prompt — more likely to get a full keyword set.
                        local aiCount = 0
                        for _, kw in ipairs(keywords) do
                            if kw.score < 1.0 then aiCount = aiCount + 1 end
                        end
                        if aiCount < 5 and not parseErr then
                            -- Determine the best focused prompt for the retry.
                            -- If the first pass was auto-detect and returned a
                            -- recognised category, use that category's prompt.
                            -- Otherwise fall back to the portrait prompt (most
                            -- detailed — works reasonably for any subject).
                            local detectedCategory = nil
                            for _, kw in ipairs(keywords) do
                                if kw.score >= 1.0 and PROMPTS[kw.name] then
                                    detectedCategory = kw.name; break
                                end
                            end
                            local retryPrompt
                            if activePrompt == PROMPTS['auto'] and detectedCategory then
                                retryPrompt = PROMPTS[detectedCategory]
                            elseif activePrompt == PROMPTS['auto'] then
                                retryPrompt = PROMPTS['portrait']
                            else
                                -- Already on a focused prompt — retry with a
                                -- different focused prompt (auto) for variety
                                retryPrompt = PROMPTS['auto']
                            end
                            waitForRateLimit()
                            local r2, e2 = callGeminiAPI(apiKey, imgData, retryPrompt)
                            if r2 and not e2 then
                                estimatedSpend = estimatedSpend + COST_PER_IMAGE
                                local kw2, cap2 = parseKeywords(r2)
                                kw2 = kw2 or {}
                                local cnt2 = 0
                                for _, kw in ipairs(kw2) do
                                    if kw.score < 1.0 then cnt2 = cnt2 + 1 end
                                end
                                if cnt2 > aiCount then keywords=kw2; caption=cap2 end
                            end
                        end

                        -- Inject orientation + ratio
                        local orientation, ratio = getOrientationAndRatio(photo)
                        if ratio       then table.insert(keywords,1,{name=ratio,      score=1.0}) end
                        if orientation then table.insert(keywords,1,{name=orientation,score=1.0}) end

                        -- Inject camera + lens from EXIF
                        local cam  = cleanMeta(photo:getFormattedMetadata('cameraModel'))
                        local lens = cleanMeta(photo:getFormattedMetadata('lens'))
                        if lens then table.insert(keywords,1,{name=lens, score=1.0}) end
                        if cam  then table.insert(keywords,1,{name=cam,  score=1.0}) end

                        table.insert(scanResults, {
                            photo=photo, uuid=uuid, name=name,
                            keywords=keywords, caption=caption, err=parseErr,
                        })
                    end
                end

                doneCount = doneCount + 1
            end
            workersDone = workersDone + 1
        end

        for w = 1, NUM_WORKERS do
            LrTasks.startAsyncTask(supremeWorker)
        end

        -- ── Progress loop ──────────────────────────────────────────────────────
        local scanStart    = os.time()
        local wdLast       = -1
        local wdSecs       = 0
        local WD_LIMIT     = 120

        while workersDone < NUM_WORKERS do
            if progress:isCanceled() then break end
            LrTasks.sleep(0.2)

            local elapsed = os.time() - scanStart
            local cap
            if elapsed > 5 and doneCount > 0 then
                local rate = doneCount / elapsed
                local left = (#photos - doneCount) / rate
                local eta  = left >= 3600
                    and string.format('%.1f hrs left', left/3600)
                    or  left >= 60
                        and string.format('%d min left', math.ceil(left/60))
                        or  string.format('%d sec left', math.ceil(left))
                cap = string.format('Processing %d / %d  •  %.0f/min  •  %s  •  $%.4f',
                    doneCount, #photos, rate*60, eta, estimatedSpend)
            else
                cap = string.format('Processing %d / %d photos…', doneCount, #photos)
            end
            progress:setCaption(cap)
            progress:setPortionComplete(doneCount, #photos)

            if doneCount ~= wdLast then
                wdLast = doneCount; wdSecs = 0
            else
                wdSecs = wdSecs + 0.2
                if wdSecs >= WD_LIMIT then
                    workerErrors[#workerErrors+1] = 'Workers stopped responding'
                    break
                end
            end
        end

        progress:done()

        -- Save scan results so a crash during apply can be resumed next run
        saveResumeState(scanResults, pickedStyle)

        end -- if not skipScan

        -- ── Apply: erase all keywords, write fresh ones ────────────────────────
        local applyProgress = LrProgressScope {
            title = string.format('Writing keywords to %d photo%s…',
                #scanResults, #scanResults == 1 and '' or 's'),
        }

        local written, errors, safetySkips, thumbFails = 0, 0, 0, 0

        catalog:withWriteAccessDo('Keyworder Supreme: erase and re-keyword', function()
            for idx, result in ipairs(scanResults) do
                applyProgress:setPortionComplete(idx-1, #scanResults)

                if result.err then
                    if tostring(result.err):find('^skipped:safety:') then
                        safetySkips = safetySkips + 1
                    elseif result.err == 'Could not load image thumbnail' then
                        thumbFails = thumbFails + 1; errors = errors + 1
                    else
                        errors = errors + 1
                    end
                elseif #result.keywords > 0 then
                    -- 1. Erase ALL existing keywords
                    for _, kw in ipairs(result.photo:getRawMetadata('keywords') or {}) do
                        result.photo:removeKeyword(kw)
                    end
                    -- 2. Add fresh keywords (flat, no parent hierarchy)
                    for _, kw in ipairs(result.keywords) do
                        local kwObj = catalog:createKeyword(kw.name, {}, true, nil, true)
                        if kwObj then result.photo:addKeyword(kwObj) end
                    end
                    -- 3. Workflow markers
                    local marker = catalog:createKeyword('AI keyworded', {}, false, nil, true)
                    if marker then result.photo:addKeyword(marker) end
                    -- 'ks-done' is unique to Keyworder Supreme — lets you filter
                    -- photos NOT yet processed for batch/resume workflows
                    local ksDone = catalog:createKeyword('ks-done', {}, false, nil, true)
                    if ksDone then result.photo:addKeyword(ksDone) end
                    -- 4. IPTC caption
                    if result.caption and result.caption ~= '' then
                        result.photo:setRawMetadata('caption', result.caption)
                    end
                    written = written + 1
                end
            end
        end)

        applyProgress:done()

        -- ── XMP write phase ───────────────────────────────────────────────────
        local xmpWritten = 0
        local xmpErr     = nil
        if writeXmp and written > 0 then
            local xmpProgress = LrProgressScope {
                title = string.format('Writing XMP metadata for %d photo%s…',
                    written, written == 1 and '' or 's'),
            }
            xmpProgress:setCaption('Saving to disk…')
            local xmpIdx = 0
            for _, result in ipairs(scanResults) do
                if not result.err and #result.keywords > 0 then
                    xmpIdx = xmpIdx + 1
                    xmpProgress:setPortionComplete(xmpIdx - 1, written)
                    local ok, err = pcall(function() result.photo:saveMetadata() end)
                    if ok then
                        xmpWritten = xmpWritten + 1
                    elseif not xmpErr then
                        xmpErr = err   -- capture first failure; keep going
                    end
                    if xmpIdx % 20 == 0 then LrTasks.yield() end
                end
            end
            xmpProgress:done()
        end

        -- ── Smart collections phase ───────────────────────────────────────────
        local smartCollCount = 0
        if createSmartColls and written > 0 then

            -- Collect every unique keyword name that was actually applied
            local allKwNames = {}
            local kwSeen     = {}
            for _, result in ipairs(scanResults) do
                if not result.err then
                    for _, kw in ipairs(result.keywords or {}) do
                        if not kwSeen[kw.name] then
                            kwSeen[kw.name] = true
                            allKwNames[#allKwNames+1] = kw.name
                        end
                    end
                end
            end

            -- Build keyword → group lookup from KeywordGroups
            local kwToGroup = {}
            for _, group in ipairs(KeywordGroups) do
                for _, kw in ipairs(group.keywords) do
                    kwToGroup[kw:lower()] = group.name
                end
            end

            local scProgress = LrProgressScope {
                title = 'Creating smart collections…',
            }

            -- Pre-create root set and all group sub-sets
            local rootSet   = nil
            local groupSets = {}
            catalog:withWriteAccessDo('Keyworder Supreme: create collection sets', function()
                rootSet = catalog:createCollectionSet('Keyworder Supreme', nil, true)
                for _, group in ipairs(KeywordGroups) do
                    groupSets[group.name] = catalog:createCollectionSet(group.name, rootSet, true)
                end
                if not groupSets['Other'] then
                    groupSets['Other'] = catalog:createCollectionSet('Other', rootSet, true)
                end
            end)

            -- One smart collection per keyword
            for idx, kwName in ipairs(allKwNames) do
                scProgress:setPortionComplete(idx - 1, #allKwNames)
                scProgress:setCaption(kwName)

                local groupName = kwToGroup[kwName:lower()] or 'Other'
                local groupSet  = groupSets[groupName] or groupSets['Other']

                catalog:withWriteAccessDo('Keyworder Supreme: smart collection ' .. kwName, function()
                    catalog:createSmartCollection(kwName, {
                        combine = 'intersect',
                        {
                            criteria  = 'keywords',
                            operation = 'words',
                            value     = kwName,
                            value2    = '',
                        },
                    }, groupSet, true)
                end)
                smartCollCount = smartCollCount + 1
                LrTasks.yield()
            end

            scProgress:done()
        end

        -- ── Summary ────────────────────────────────────────────────────────────
        local msg = {}
        msg[#msg+1] = string.format('%d photo%s re-keyworded (all previous keywords erased and replaced).',
            written, written == 1 and '' or 's')
        if safetySkips > 0 then
            msg[#msg+1] = string.format('%d photo%s skipped by Gemini safety filter.',
                safetySkips, safetySkips == 1 and '' or 's')
        end
        if thumbFails > 0 then
            msg[#msg+1] = string.format(
                '%d photo%s had no preview thumbnail.\n'
             .. 'Fix: Library → Previews → Build Standard-Sized Previews, then re-run.',
                thumbFails, thumbFails == 1 and '' or 's')
        end
        if errors - thumbFails > 0 then
            msg[#msg+1] = string.format('%d API error%s — check your API key and internet connection.',
                errors-thumbFails, (errors-thumbFails) == 1 and '' or 's')
        end
        if #workerErrors > 0 then
            msg[#msg+1] = 'Warning: '..workerErrors[1]
        end
        if writeXmp then
            if xmpErr then
                msg[#msg+1] = string.format(
                    'XMP warning: keywords written to catalogue but some XMP saves failed:\n%s',
                    tostring(xmpErr))
            else
                msg[#msg+1] = string.format(
                    '%d XMP sidecar%s / file%s updated on disk.',
                    xmpWritten, xmpWritten == 1 and '' or 's',
                    xmpWritten == 1 and '' or 's')
            end
        end
        if smartCollCount > 0 then
            msg[#msg+1] = string.format(
                '%d smart collection%s created / updated in the "Keyworder Supreme" set.',
                smartCollCount, smartCollCount == 1 and '' or 's')
        end
        msg[#msg+1] = string.format('\nEstimated API cost: $%.4f', estimatedSpend)

        -- Run completed — discard the resume file
        deleteResumeState()

        LrDialogs.message('Keyworder Supreme — Done',
            table.concat(msg, '\n'),
            (errors > 0 or #workerErrors > 0) and 'warning' or 'info')

    end)  -- end startAsyncTask
end)  -- end callWithContext
