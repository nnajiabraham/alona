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

/**
 * The model lineup, from docs/research/local-models-2026-11.md. Each host's
 * artifacts are added once that host's engine has run them end to end.
 */
export const LINEUP: Record<TierId, Tier> = {
  lite: {
    id: 'lite',
    label: 'Lite',
    blurb: 'Smallest and fastest. English transcripts and draft-quality notes.',
    stt: { name: 'Moonshine Small', artifacts: {} },
    llm: { name: 'Qwen3.5 0.8B', artifacts: {} },
  },
  balanced: {
    id: 'balanced',
    label: 'Balanced',
    blurb: 'Accurate transcripts in 25 languages and solid notes.',
    stt: { name: 'Parakeet v3', artifacts: {} },
    llm: { name: 'Qwen3.5 2B', artifacts: {} },
  },
  quality: {
    id: 'quality',
    label: 'Quality',
    blurb: 'The most accurate transcripts and the most thorough notes.',
    stt: { name: 'Granite Speech 5', artifacts: {} },
    llm: { name: 'Qwen3.5 9B', artifacts: {} },
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
