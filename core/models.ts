import artifacts from './artifacts.json';
import type { Artifact } from './engine';
import { TIERS, type Host, type TierId } from './types';

export interface ModelInfo {
  name: string;
  /** The same model packaged for each host's runtime. A host with no entry cannot run it. */
  artifacts: Partial<Record<Host, Artifact>>;
}

export interface Tier {
  id: TierId;
  label: string;
  blurb: string;
  stt: ModelInfo;
  llm: ModelInfo;
}

const MOONSHINE: Artifact = artifacts['moonshine-base-en.sherpa'];
const PARAKEET: Artifact = artifacts['parakeet-tdt-0.6b-v3.sherpa'];
const QWEN_08B: Artifact = artifacts['qwen3.5-0.8b.gguf'];
const QWEN_2B: Artifact = artifacts['qwen3.5-2b.gguf'];
const QWEN_9B: Artifact = artifacts['qwen3.5-9b.gguf'];

/**
 * The model lineup. Files and hashes are pinned in artifacts.json by
 * tools/pin-models.mjs. A host is listed under a model only after that
 * host's engine has run it end to end.
 */
export const LINEUP: Record<TierId, Tier> = {
  lite: {
    id: 'lite',
    label: 'Lite',
    blurb: 'Smallest and fastest. English transcripts and draft-quality notes.',
    stt: { name: 'Moonshine Base', artifacts: { macos: MOONSHINE } },
    llm: { name: 'Qwen3.5 0.8B', artifacts: { macos: QWEN_08B } },
  },
  balanced: {
    id: 'balanced',
    label: 'Balanced',
    blurb: 'Accurate transcripts in 25 languages and solid notes.',
    stt: { name: 'Parakeet v3', artifacts: { macos: PARAKEET } },
    llm: { name: 'Qwen3.5 2B', artifacts: { macos: QWEN_2B } },
  },
  quality: {
    id: 'quality',
    label: 'Quality',
    blurb: 'The same accurate transcripts with the most thorough notes.',
    stt: { name: 'Parakeet v3', artifacts: { macos: PARAKEET } },
    llm: { name: 'Qwen3.5 9B', artifacts: { macos: QWEN_9B } },
  },
};

export interface TierArtifacts {
  stt: Artifact;
  llm: Artifact;
}

export function tierArtifacts(host: Host, tier: TierId): TierArtifacts | null {
  const stt = LINEUP[tier].stt.artifacts[host];
  const llm = LINEUP[tier].llm.artifacts[host];
  return stt && llm ? { stt, llm } : null;
}

export const shippedTiers = (host: Host): TierId[] => TIERS.filter((tier) => tierArtifacts(host, tier) !== null);

/** Stand-in artifacts for the demo engine, which downloads nothing. */
export const demoArtifacts = (tier: TierId): TierArtifacts => ({
  stt: { id: `demo-${tier}-stt`, runtime: 'demo', files: [] },
  llm: { id: `demo-${tier}-llm`, runtime: 'demo', files: [] },
});

export function downloadBytes(artifacts: TierArtifacts): number {
  return [...artifacts.stt.files, ...artifacts.llm.files].reduce((sum, f) => sum + f.bytes, 0);
}

export function sizeLabel(bytes: number): string {
  if (bytes <= 0) return '';
  const gb = bytes / 1e9;
  return gb >= 1 ? `${gb.toFixed(1)} GB` : `${Math.max(1, Math.round(bytes / 1e6))} MB`;
}
