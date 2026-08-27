/**
 * 单首曲目的数据模型
 */
@Observed
export class Track {
  name: string;
  uri: string;
  // 时长(毫秒),-1 表示尚未从播放器读取到
  duration: number;
  accent: string;
  accent2: string;

  constructor(name: string, uri: string, accent: string, accent2: string) {
    this.name = name;
    this.uri = uri;
    this.duration = -1;
    this.accent = accent;
    this.accent2 = accent2;
  }
}

// 每次新增曲目时按顺序循环取一组配色,呼应彩色炫彩主题
export const ACCENT_PAIRS: string[][] = [
  ['#FF3E9A', '#FF7A45'],
  ['#2FE6D0', '#3E7CFF'],
  ['#FFC93C', '#FF3E9A'],
  ['#B14EFF', '#2FE6D0'],
  ['#FF7A45', '#FFC93C'],
  ['#3E7CFF', '#B14EFF'],
];

export function fmtTime(ms: number): string {
  if (!Number.isFinite(ms) || ms < 0) {
    return '00:00';
  }
  const totalSec = Math.floor(ms / 1000);
  const m = Math.floor(totalSec / 60).toString().padStart(2, '0');
  const s = (totalSec % 60).toString().padStart(2, '0');
  return `${m}:${s}`;
}
