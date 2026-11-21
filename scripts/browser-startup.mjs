// Fixture startup metadata only. Never reads browser profile or page data.
import { execFileSync } from "node:child_process";
import { realpathSync, statfsSync, writeFileSync } from "node:fs";
import { availableParallelism, freemem, platform, arch } from "node:os";
import { performance } from "node:perf_hooks";

export function startupDiagnostics(chrome, directory, overrides = {}) {
  const io = {
    realpath: realpathSync,
    version: (binary) =>
      execFileSync(binary, ["--version"], {
        encoding: "utf8",
        timeout: 1000,
        maxBuffer: 1024,
        stdio: ["ignore", "pipe", "ignore"],
      }),
    disk: statfsSync,
    cpu: availableParallelism,
    memory: freemem,
    now: () => performance.now(),
    write: writeFileSync,
    ...overrides,
  };
  const data = {
    node: process.version,
    os: platform(),
    arch: arch(),
    chrome,
    events: [],
  };
  const sample = (key, read) => {
    try {
      data[key] = read();
    } catch {
      data[key] = "unknown";
    }
  };
  sample("resolvedChrome", () => io.realpath(chrome));
  sample("chromeVersion", () => io.version(chrome).slice(0, 512).trim());
  sample("cpuCount", () => io.cpu());
  sample("freeMemoryBytes", () => io.memory());
  sample("temporaryFreeBytes", () => {
    const disk = io.disk(directory);
    return disk.bavail * disk.bsize;
  });
  let started;
  const mark = (stage, details = {}) => {
    if (data.events.length >= 16) {
      return;
    }
    if (stage === "spawn-request") {
      started = io.now();
    }
    data.events.push({
      stage,
      milliseconds: started === undefined ? 0 : Math.round(io.now() - started),
      ...details,
    });
  };
  return {
    mark,
    write(path) {
      try {
        const json = JSON.stringify(data, null, 2);
        if (Buffer.byteLength(json) > 16_384) {
          return false;
        }
        io.write(path, json);
        return true;
      } catch {
        return false;
      }
    },
  };
}
