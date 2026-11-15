import type { DeviceFacts } from './engine';
import { TIERS, type Host, type TierId } from './types';

export interface TierVerdict {
  tier: TierId;
  runnable: boolean;
  /** One sentence the settings screen shows under the tier. */
  reason: string;
}

export interface Assessment {
  recommended: TierId;
  verdicts: TierVerdict[];
}

const GB = (n: number): string => `${Math.round(n)} GB`;

const needsMemory = (needed: number, d: DeviceFacts, what: string): string =>
  `Needs ${needed} GB of memory. This ${what} has ${GB(d.memoryGB)}.`;

/**
 * Why this device cannot run a tier, or null when it can. Rows follow the
 * decision table in docs/research/local-models-2026-11.md, section 2.2.
 */
function blocker(host: Host, d: DeviceFacts, tier: TierId): string | null {
  if (tier === 'lite') return null;
  if (host === 'web') {
    if (tier === 'quality') return 'Too large for a browser. The desktop app can run it.';
    if (d.iosBrowser) return 'Browsers on iPhone and iPad cap memory, so this model cannot load.';
    if (!d.gpu) return 'Needs WebGPU, which this browser does not have.';
    if (d.memoryGB !== 0 && d.memoryGB < 8) return needsMemory(8, d, 'browser');
    if (d.gpuMaxBufferGB < 1) return 'Needs a larger GPU buffer than this browser allows.';
    if (d.storageFreeGB < 4) return 'Needs 4 GB of free browser storage.';
    return null;
  }
  const what = d.formFactor === 'phone' ? 'device' : 'computer';
  if (d.memoryGB < 6) return needsMemory(6, d, what);
  if (tier === 'balanced') return null;
  if (d.formFactor === 'phone') return 'Too large for phones and tablets.';
  if (d.memoryGB < 16) return needsMemory(16, d, what);
  if (!d.appleSilicon) return 'Needs Apple silicon.';
  return null;
}

export function assess(host: Host, device: DeviceFacts, shipped: readonly TierId[]): Assessment {
  const verdicts = TIERS.filter((tier) => shipped.includes(tier)).map((tier): TierVerdict => {
    const why = blocker(host, device, tier);
    return { tier, runnable: why === null, reason: why ?? 'Runs on this device.' };
  });
  const recommended = verdicts.filter((v) => v.runnable).at(-1)?.tier ?? 'lite';
  return { recommended, verdicts };
}

/** The tier in effect: the person's pick when this device can run it, else the recommended one. */
export function effectiveTier(assessment: Assessment, picked: TierId | 'auto'): TierId {
  if (picked === 'auto') return assessment.recommended;
  const verdict = assessment.verdicts.find((v) => v.tier === picked);
  return verdict?.runnable ? picked : assessment.recommended;
}
