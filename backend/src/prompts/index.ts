/**
 * v24 prompt builders. Three artifact types: logo, carousel, brand film.
 *
 * Architecture:
 *  - Static preamble (ROLE + business inputs + COLOUR + TYPOGRAPHY) is
 *    cached by OpenAI across calls when the prompt is structured with
 *    a stable prefix. We keep the preamble as the first ~60% of the
 *    prompt string and append the dynamic per-concept suffix.
 *  - Logo: Free = 1 call (Concept 5 only). Pro = 1 Project per concept
 *    (5 Projects, 1 call each).
 *  - Carousel: 1 Project = 5 sequential calls (one per slide position
 *    within a fixed campaign). Free uses Campaign 5; Pro auto-distributes
 *    the 5 campaigns across 5 Projects.
 *  - Film: 1 Project = 1 call (Free uses Concept 5; Pro uses 1 concept
 *    per Project, all 5 across 5 Projects).
 */

export interface BusinessContext {
  name: string;
  industry: string; // may be CSV from multi-select picker
  tagline: string | null;
  tone: string | null; // CSV, max 2
  /** v24: palette keys CSV (max 2). Keys: warm, cool, monochrome, earthy, pastel, vibrant */
  palettePreference: string | null;
  /** v24: font keys CSV (max 2). Keys: modern_default, editorial, tech_forward, elegant_serif, utility, bold_display */
  fontPreference: string | null;
}

/** Reference photos split by category. All optional. */
export interface ReferenceBundle {
  logoUrl?: string;
  ambassadorUrl?: string;
  productUrls: string[]; // up to 5
  otherUrls: string[];   // up to 2
}

/**
 * BrandAmbassador table stores every uploaded reference photo with
 * a label like "Logo 1", "Ambassador 1", "Product 3", "Other 2". Split
 * that flat list into the four categories the prompts care about.
 */
export function categorizeReferences(
  photoUrls: string[],
  angleLabels: string[],
): ReferenceBundle {
  const bundle: ReferenceBundle = { productUrls: [], otherUrls: [] };

  for (let i = 0; i < photoUrls.length; i++) {
    const label = (angleLabels[i] ?? "").toLowerCase();
    const url = photoUrls[i];
    if (!url) continue;

    if (label.startsWith("logo")) {
      bundle.logoUrl ??= url;
    } else if (label.startsWith("ambassador")) {
      bundle.ambassadorUrl ??= url;
    } else if (label.startsWith("product")) {
      bundle.productUrls.push(url);
    } else {
      bundle.otherUrls.push(url);
    }
  }

  return bundle;
}

function firstIndustry(industryCsv: string): string {
  return industryCsv.split(",")[0]?.trim() || industryCsv;
}

function toneClause(tone: string | null): string {
  if (!tone || !tone.trim()) return "modern and premium";
  return tone;
}

// ---------------------------------------------------------------------
// v24 palette + font descriptors
// ---------------------------------------------------------------------

/**
 * Hex-coded palette list. The Flutter app mirrors this in
 * flutter_app/lib/data/palette_styles.dart — keys + hexes must stay in
 * sync. Anything missing here falls back to the warm palette, which is
 * the source of the "logo doesn't match my colour pick" bug.
 */
const PALETTE_HEX: Record<string, string> = {
  warm: "#8B1A2A, #B85028, #D4A72C",
  cool: "#0F2C44, #1F8FAA, #C0C0C0",
  monochrome: "#1A1A1A, #666666, #FFF5E1",
  earthy: "#5C4033, #708238, #D2B48C",
  pastel: "#FFB6C1, #E6E6FA, #98FF98",
  vibrant: "#7DF9FF, #FF00FF, #FFEA00",
  jewel_tones: "#046A38, #0F52BA, #9B111E",
  sunset: "#FF7F50, #FFDAB9, #E6E6FA",
  ocean: "#003366, #00CED1, #93E9BE",
  forest: "#1B4D3E, #606C38, #8FBC8F",
  desert: "#C2B280, #E2725B, #A0522D",
  royal: "#4B0082, #FFD700, #FFFFF0",
  minimalist: "#FFFFFF, #36454F, #D3D3D3",
  neon: "#CCFF00, #FF1493, #00FFFF",
  autumn: "#CC5500, #FFDB58, #DC143C",
  winter: "#AFDBF5, #C0C0C0, #FFFFFF",
  tropical: "#40E0D0, #FFC324, #FF77FF",
  vintage: "#FFDB58, #008080, #B7410E",
  muted: "#9CAF88, #DCAE96, #B38B6D",
  high_contrast: "#000000, #FFD300, #E10600",
  luxe_gold: "#014421, #F7E7CE, #D4AF37",
};

/**
 * Category-only font descriptions. Mirrors
 * flutter_app/lib/data/font_pairs.dart — keys must match exactly,
 * otherwise the prompt falls back to modern_default.
 */
const FONT_CATEGORY_DESC: Record<string, string> = {
  modern_default: "Modern sans display + clean sans body",
  editorial: "Luxury serif display + neutral sans body",
  tech_forward: "Geometric sans display + neutral sans body",
  elegant_serif: "Heritage serif display + clean sans body",
  utility: "Functional sans display + neutral sans body",
  bold_display: "Bold condensed display + neutral sans body",
  classic_serif: "Warm literary serif display + matching serif body",
  condensed: "Tall condensed display + open sans body",
  handwritten: "Casual handwritten display + soft sans body",
  retro: "Vintage display serif + neutral sans body",
  corporate: "Friendly geometric sans display + matching sans body",
  brutalist: "Mono display + structured sans body",
  geometric: "Geometric sans display + matching geometric sans body",
  humanist: "Rounded humanist sans display + matching humanist sans body",
  luxury: "Refined serif display + elegant sans body",
  sports: "Heavy condensed display + condensed sans body",
  educational: "Readable serif display + neutral sans body",
  playful: "Rounded display + soft sans body",
  minimal_mono: "Mono display + neutral sans body",
  swiss: "Neutral sans display + matching sans body",
  script: "Flowing script display + clean sans body",
};

function paletteClause(csv: string | null): string {
  if (!csv || !csv.trim()) return PALETTE_HEX.warm;
  const keys = csv.split(",").map((s) => s.trim()).filter(Boolean);
  return keys
    .map((k) => `${k} (${PALETTE_HEX[k] ?? PALETTE_HEX.warm})`)
    .join("; ");
}

function fontClause(csv: string | null): string {
  if (!csv || !csv.trim()) return FONT_CATEGORY_DESC.modern_default;
  const keys = csv.split(",").map((s) => s.trim()).filter(Boolean);
  return keys
    .map((k) => FONT_CATEGORY_DESC[k] ?? FONT_CATEGORY_DESC.modern_default)
    .join("; ");
}

/**
 * Stable preamble shared by every logo / carousel / film prompt. Sent
 * FIRST so OpenAI's prompt cache hits across calls (5x cheaper).
 */
function buildPreamble(ctx: BusinessContext, refs: ReferenceBundle): string {
  const refsClause = refs.logoUrl
    ? "If a logo is uploaded: treat it as the company's existing identity. " +
      "Do NOT completely redesign. Preserve recognizability. Improve icon " +
      "geometry, proportions, spacing, typography, balance, scalability, " +
      "premium appearance, readability, consistency."
    : "No existing logo uploaded. Design an entirely original logo. " +
      "Do NOT imitate existing famous brands.";

  return [
    "==================================================",
    "BUSINESS INFORMATION",
    "==================================================",
    `Business Name: ${ctx.name}`,
    `Industry: ${firstIndustry(ctx.industry)}`,
    `Brand Tagline: ${ctx.tagline ?? "(none provided)"}`,
    `Brand Tone: ${toneClause(ctx.tone)}`,
    `Preferred Colour Palette: ${paletteClause(ctx.palettePreference)}`,
    `Typography / Calligraphy Style: ${fontClause(ctx.fontPreference)}`,
    "",
    "==================================================",
    "REFERENCE LOGO",
    "==================================================",
    refsClause,
  ].join("\n");
}

// ---------------------------------------------------------------------
// LOGO — 5 concepts, called per concept per Project
// ---------------------------------------------------------------------

export const LOGO_CONCEPTS = [
  { index: 1, label: "Minimal geometric identity." },
  { index: 2, label: "Premium luxury identity." },
  { index: 3, label: "Creative symbolic identity." },
  { index: 4, label: "Elegant typography-driven identity." },
  { index: 5, label: "Modern abstract brandmark." },
] as const;

const LOGO_ROLE = `You are the Creative Director of the world's most prestigious
branding agency. Your work is comparable to Pentagram, Landor, Wolff
Olins, Collins, MetaDesign, Interbrand and DesignStudio. Your objective
is NOT to generate random logos. Your objective is to create world-class
commercial brand identities suitable for Fortune 500 companies and
premium startups.`;

function logoSuffix(conceptIndex: number): string {
  const concept = LOGO_CONCEPTS.find((c) => c.index === conceptIndex)!;
  return [
    "",
    "==================================================",
    "DESIGN DIRECTION FOR THIS IMAGE",
    "==================================================",
    `Concept ${concept.index} of 5: ${concept.label}`,
    "",
    "ICON DESIGN: original, simple, timeless, memorable, recognizable, balanced, " +
      "grid aligned, scalable to favicon / app icon / website / packaging / " +
      "signage / embroidery / merchandise.",
    "",
    "AVOID generic symbols (light bulbs, globes, swooshes, arrows, " +
      "puzzles, handshakes, leaves) unless truly appropriate.",
    "",
    "COMPOSITION: perfect alignment, strong negative space, optical balance, " +
      "golden-ratio proportions, vector appearance.",
    "",
    "BACKGROUND: pure white. No mockups, paper, walls, shadows, perspective. " +
      "Display only the logo.",
    "",
    "OUTPUT: render ONE logo matching the chosen Concept above. " +
      "Icon + wordmark + optional tagline. Do not include the other 4 concepts.",
  ].join("\n");
}

export function buildLogoPrompt(
  ctx: BusinessContext,
  refs: ReferenceBundle,
  conceptIndex: number,
): string {
  return [
    LOGO_ROLE,
    "",
    buildPreamble(ctx, refs),
    logoSuffix(conceptIndex),
  ].join("\n");
}

// ---------------------------------------------------------------------
// CAROUSEL — 5 campaigns, 5 slides each, called per slide per Project
// ---------------------------------------------------------------------

export const CAROUSEL_CAMPAIGNS = [
  { index: 1, label: "Educational", description: "Teach something valuable. Authority building. Professional." },
  { index: 2, label: "Storytelling", description: "Emotion driven. Customer journey. Transformation." },
  { index: 3, label: "Problem → Solution", description: "Pain points. Benefits. Clear CTA." },
  { index: 4, label: "Premium Brand Showcase", description: "Luxury. Beautiful visuals. Minimal text. Aspirational." },
  { index: 5, label: "High Conversion Sales Carousel", description: "Attention grabbing. Urgency. Offers. Social proof. Strong CTA." },
] as const;

export const CAROUSEL_SLIDES = [
  { position: 1, role: "Powerful hook. Eye-catching cover. Large headline. Minimal copy." },
  { position: 2, role: "Introduce problem or insight." },
  { position: 3, role: "Present solution or value." },
  { position: 4, role: "Build trust. Features. Benefits. Testimonials. Statistics. Before-after." },
  { position: 5, role: "Strong call to action. Website. QR placeholder. Contact. Social handles." },
] as const;

const CAROUSEL_ROLE = `You are the Creative Director of the world's best advertising
agency. Your work rivals Apple, Nike, Coca-Cola, Airbnb, Tesla, Spotify,
Rolex, Netflix, Adobe, Chanel and Formula One. Your objective is to
create world-class Instagram and LinkedIn carousel campaigns that look
professionally designed, emotionally engaging, visually stunning and
commercially effective. The final output must feel like it was designed
by an award-winning creative agency.`;

function carouselSuffix(campaignIndex: number, slidePosition: number): string {
  const campaign = CAROUSEL_CAMPAIGNS.find((c) => c.index === campaignIndex)!;
  const slide = CAROUSEL_SLIDES.find((s) => s.position === slidePosition)!;
  return [
    "",
    "==================================================",
    "DESIGN DIRECTION FOR THIS IMAGE",
    "==================================================",
    `Campaign ${campaign.index} of 5: ${campaign.label}`,
    `Campaign mood: ${campaign.description}`,
    "",
    `Slide ${slide.position} of 5: ${slide.role}`,
    "",
    "VISUAL STYLE: premium agency work. Large typography, beautiful " +
      "spacing, excellent hierarchy, professional layouts, strong " +
      "composition, editorial design, magazine quality, high-end branding.",
    "",
    "OUTPUT: render ONE slide matching the specified Campaign and Slide. " +
      "Do not include other slides or campaigns in this image.",
  ].join("\n");
}

export function buildCarouselSlidePrompt(
  ctx: BusinessContext,
  refs: ReferenceBundle,
  campaignIndex: number,
  slidePosition: number,
): string {
  return [
    CAROUSEL_ROLE,
    "",
    buildPreamble(ctx, refs),
    carouselSuffix(campaignIndex, slidePosition),
  ].join("\n");
}

/**
 * Free tier: 1 Project with campaignIndex = 5, all 5 slides.
 * Pro tier: 5 Projects, one per campaign (1..5), each with 5 slides.
 */
export function pickCarouselCampaignForFreeTier(): number {
  return 5;
}

// ---------------------------------------------------------------------
// BRAND FILM — 5 concepts, 1 per Project (Free = Concept 5, Pro = 1..5)
// ---------------------------------------------------------------------

export const FILM_CONCEPTS = [
  {
    index: 1,
    label: "Emotional Storytelling",
    sequence: "0-2 sec: Dramatic cinematic establishing shot. 2-5 sec: Beautiful slow-motion product reveal with premium lighting. 5-8 sec: Customer interacting naturally with the product or service. 8-10 sec: Elegant logo reveal with tagline on a clean premium background.",
    style: "Apple commercial aesthetics, luxury advertising, Hollywood cinematography, anamorphic lens, shallow depth of field, golden hour lighting, volumetric light, ultra-realistic textures, cinematic color grading, smooth camera movements, premium composition.",
  },
  {
    index: 2,
    label: "Product Hero",
    sequence: "0-2 sec: Extreme macro detail. 2-4 sec: Rotating hero shot. 4-7 sec: Dynamic product usage with elegant lighting. 7-10 sec: Premium logo animation and tagline.",
    style: "Luxury product cinematography, Apple keynote quality, Rolex advertising, macro photography, reflective surfaces, cinematic studio lighting, slow motion, ultra-sharp details, elegant transitions.",
  },
  {
    index: 3,
    label: "Lifestyle Commercial",
    sequence: "0-3 sec: Real people naturally using the brand. 3-6 sec: Happy emotional interaction in a premium environment. 6-8 sec: Beautiful close-up of product or service. 8-10 sec: Logo and tagline appear elegantly.",
    style: "Natural performances, warm cinematic lighting, luxury interiors, premium wardrobe, authentic emotions, smooth gimbal movement, modern commercial aesthetics, cinematic color grading.",
  },
  {
    index: 4,
    label: "Fast-paced Modern Commercial",
    sequence: "0-2 sec: Fast attention-grabbing opening. 2-5 sec: Multiple quick premium product and lifestyle shots. 5-8 sec: Strong visual brand message. 8-10 sec: Animated logo with tagline.",
    style: "Dynamic camera movement, whip transitions, speed ramps, premium motion graphics, energetic editing, modern typography, cinematic lighting, bold compositions, high-energy commercial production.",
  },
  {
    index: 5,
    label: "Brand Signature Film",
    sequence: "0-2 sec: Beautiful cinematic opening. 2-5 sec: Brand's defining moment with customer or product. 5-8 sec: Powerful emotional visual. 8-10 sec: Elegant logo animation, tagline, and subtle brand sound cue.",
    style: "Minimal, premium, cinematic, luxury advertising, Netflix-quality visuals, natural lighting, smooth cinematic camera moves, rich cinematic color grading, clean compositions, timeless aesthetic. Photorealistic, 4K, 16:9, Hollywood commercial quality.",
  },
] as const;

const FILM_ROLE = `You are an award-winning Hollywood Commercial Director, Brand
Strategist and Creative Director. Your work is comparable to
advertisements created by Apple, Nike, Mercedes-Benz, BMW, Coca-Cola,
Rolex, Samsung, Adidas, Airbnb, Netflix and Formula One. Your objective
is NOT to make generic AI videos. Your objective is to create
world-class cinematic brand films capable of winning Cannes Lions,
D&AD and Clio Awards. The final films should emotionally connect with
customers while communicating the brand's identity.`;

function filmSuffix(conceptIndex: number): string {
  const concept = FILM_CONCEPTS.find((c) => c.index === conceptIndex)!;
  return [
    "",
    "==================================================",
    "DESIGN DIRECTION FOR THIS FILM",
    "==================================================",
    `Concept ${concept.index} of 5: ${concept.label}`,
    `Sequence: ${concept.sequence}`,
    `Style: ${concept.style}`,
    "",
    "CAMERA: professional cinematography — drone, steadicam, gimbal " +
      "tracking, macro close-ups, low-angle hero shots, slow motion, " +
      "handheld documentary moments, wide cinematic landscapes. Natural " +
      "camera movement.",
    "",
    "COLOUR GRADING: use the selected brand palette naturally. Premium " +
      "cinematic grading. Rich contrast. Beautiful skin tones. Luxury " +
      "highlights.",
    "",
    "AUDIO: ambient sounds + background music + sound effects + " +
      "voice-over tone. Premium cinematic.",
    "",
    "ON-SCREEN TEXT: minimal, elegant, premium typography. Never " +
      "overcrowd the screen.",
    "",
    "ENDING: elegant logo reveal + business name + tagline + website " +
      "placeholder + social media placeholder + clear CTA.",
    "",
    "OUTPUT: 10-second 16:9 cinematic commercial matching Concept " +
      `${concept.index}. Aspect 16:9, photorealistic, 4K quality.`,
  ].join("\n");
}

export function buildFilmPrompt(
  ctx: BusinessContext,
  refs: ReferenceBundle,
  conceptIndex: number,
): string {
  return [
    FILM_ROLE,
    "",
    buildPreamble(ctx, refs),
    filmSuffix(conceptIndex),
  ].join("\n");
}

/** Free tier always picks the signature-film concept. */
export function pickFilmConceptForFreeTier(): number {
  return 5;
}
