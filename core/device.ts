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

/**
 * The highest tier this device can run, and why. Rows follow the decision
 * table in docs/research/local-models-2026-11.md, section 2.2.
 */
function ceiling(host: Host, d: DeviceFacts): { tier: TierId; why: string } {
  if (host === 'web') {
    if (d.iosBrowser) return { tier: 'lite', why: 'Browsers on iPhone and iPad cap memory, so larger models cannot load.' };
    if (!d.gpu) return { tier: 'lite', why: 'This browser has no WebGPU, so models run on the CPU.' };
    const memoryOk = d.memoryGB === 0 || d.memoryGB >= 8;
    if (memoryOk && d.gpuMaxBufferGB >= 1 && d.storageFreeGB >= 4) {
      return { tier: 'balanced', why: 'This browser has WebGPU and enough memory and storage.' };
    }
    return { tier: 'lite', why: 'This browser reports too little memory, GPU buffer, or storage for larger models.' };
  }
  if (d.memoryGB < 6) return { tier: 'lite', why: `This device has ${GB(d.memoryGB)} of memory.` };
  if (d.formFactor === 'phone') {
    return { tier: 'balanced', why: `This device has ${GB(d.memoryGB)} of memory. The largest models stay off phones.` };
  }
  if (d.memoryGB >= 16 && d.appleSilicon) {
    return { tier: 'quality', why: `This Mac has ${GB(d.memoryGB)} of memory and Apple silicon.` };
  }
  return { tier: 'balanced', why: `This computer has ${GB(d.memoryGB)} of memory.` };
}

export function assess(host: Host, device: DeviceFacts, shipped: readonly TierId[]): Assessment {
  const top = ceiling(host, device);
  const limit = TIERS.indexOf(top.tier);
  const verdicts = TIERS.filter((tier) => shipped.includes(tier)).map((tier): TierVerdict => {
    const runnable = TIERS.indexOf(tier) <= limit;
    return { tier, runnable, reason: runnable ? 'Runs on this device.' : top.why };
  });
  const runnable = verdicts.filter((v) => v.runnable);
  const recommended = runnable.at(-1)?.tier ?? 'lite';
  return { recommended, verdicts };
}

/** The tier in effect: the person's pick when this device can run it, else the recommended one. */
export function effectiveTier(assessment: Assessment, picked: TierId | 'auto'): TierId {
  if (picked === 'auto') return assessment.recommended;
  const verdict = assessment.verdicts.find((v) => v.tier === picked);
  return verdict?.runnable ? picked : assessment.recommended;
}
