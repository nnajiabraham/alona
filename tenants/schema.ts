// The white-label schema. One file per tenant under tenants/ calls
// `defineTenant` with a value of this shape; tools/tenant.mjs checks it and
// builds the clinic app from it. tenants/README.md explains each field.

/** A colour as six hex digits. The type admits any `#…`; `tenant.mjs check` refuses the rest. */
export type Hex = `#${string}`;

/** The colour in the light scheme and in the dark scheme. */
export interface ColorPair {
  light: Hex;
  dark: Hex;
}

/** Every colour token the clinic views use. */
export const COLOR_TOKENS = [
  'accent',
  'page',
  'card',
  'raised',
  'line',
  'text',
  'muted',
  'progressSoft',
  'progressInk',
  'attentionSoft',
  'attentionInk',
  'noticeSoft',
  'noticeInk',
] as const;

export type ColorToken = (typeof COLOR_TOKENS)[number];

export type Colors = Record<ColorToken, ColorPair>;

declare const brand: unique symbol;
type Branded<T, B extends string> = T & { readonly [brand]: B };

/** Lowercase letters, digits and hyphens, starting with a letter: the tenant's folder and build name. */
export type TenantSlug = Branded<string, 'TenantSlug'>;

/** A reverse-DNS app id, such as `org.example.notes`. */
export type BundleId = `${string}.${string}.${string}`;

export type TierChoice = 'auto' | 'lite' | 'balanced' | 'quality';

export type NonEmpty<T> = readonly [T, ...T[]];

/** One heading of a note, and one sentence telling the model what belongs under it. */
export interface TemplateSection {
  heading: string;
  guidance: string;
}

export interface NoteTemplate<Id extends string = string> {
  /** Stable id, kept in each note's record. Lowercase letters, digits and hyphens. */
  id: Id;
  name: string;
  description: string;
  sections: NonEmpty<TemplateSection>;
}

export interface Features {
  /** A pad on the recording screen for the clinician's own jottings, which the draft also uses. */
  jottings: boolean;
  /** "Copy note" once a note is reviewed. */
  copy: boolean;
  /** "Share note" (the system share sheet) once a note is reviewed. */
  share: boolean;
  /** A player for the recording on the note's screen. */
  playback: boolean;
}

export interface Support {
  /** Shown as a mailto link. */
  email?: string;
  /** Shown as a link. Must be https. */
  url?: string;
  /** Shown as text, for example opening hours. */
  hours?: string;
}

export interface TenantConfig<TemplateId extends string = string> {
  slug: TenantSlug;
  app: {
    /** The app's name on the home screen bar, the welcome and Settings. */
    name: string;
    /** The name under the icon on a phone. At most 12 characters. */
    shortName: string;
    tagline: string;
    bundleId: BundleId;
    /** Shown in Settings. */
    version: string;
  };
  colors: Colors;
  copy: {
    welcomeTitle: string;
    welcomeBody: string;
    /** The person being seen, lowercase: "patient", "client". */
    person: { singular: string; plural: string };
    /** Shown on every AI draft until it is reviewed. */
    reviewDisclaimer: string;
    /** Shown in Settings. Say what the app does; claim no regulation. */
    privacy: string;
  };
  templates: NonEmpty<NoteTemplate<TemplateId>>;
  defaults: {
    /** The id of the template a new note starts with. A type error unless a template has it. */
    template: NoInfer<TemplateId>;
    tier: TierChoice;
  };
  features: Features;
  support?: Support;
  /** A square PNG of at least 512 pixels, relative to tenants/. */
  icon: string;
}

/** The config as a tenant file writes it: the slug is a plain string until it is checked. */
export type TenantInput<TemplateId extends string> = Omit<TenantConfig<TemplateId>, 'slug'> & { slug: string };

/**
 * Declares a tenant. The type checks every field and that the default
 * template is one of the templates; `tenant.mjs check` validates what types
 * cannot (contrast, uniqueness, formats, the icon file).
 */
export function defineTenant<const TemplateId extends string>(config: TenantInput<TemplateId>): TenantConfig<TemplateId> {
  return { ...config, slug: tenantSlug(config.slug) };
}

const SLUG = /^[a-z][a-z0-9-]{1,31}$/;

export function tenantSlug(raw: string): TenantSlug {
  if (!SLUG.test(raw)) {
    throw new Error(`slug "${raw}" must be 2 to 32 lowercase letters, digits and hyphens, starting with a letter.`);
  }
  return raw as TenantSlug;
}
