import type { Files } from '../store';

/** An in-memory stand-in for the host's file system, for tests. */
export function memoryFiles(): Files & { paths(): string[] } {
  const dirs = new Map<string, Uint8Array>();
  return {
    readFile: async (path: string) => {
      const data = dirs.get(path);
      if (!data) throw Object.assign(new Error('missing'), { code: 'ENOENT' });
      return data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
    },
    atomicWriteFile: async (path: string, data: Uint8Array) => void dirs.set(path, data),
    readdir: async (path: string) => [...new Set([...dirs.keys()].filter((k) => k.startsWith(`${path}/`)).map((k) => k.slice(path.length + 1).split('/')[0]))],
    mkdir: async () => {},
    rm: async (path: string) => {
      for (const k of [...dirs.keys()]) if (k.startsWith(`${path}/`)) dirs.delete(k);
    },
    paths: () => [...dirs.keys()].sort(),
  };
}
