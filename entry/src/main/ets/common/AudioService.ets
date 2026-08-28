import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

const DOMAIN = 0x0000;

export type PlayerState =
  | 'idle' | 'initialized' | 'prepared' | 'playing'
  | 'paused' | 'stopped' | 'completed' | 'released' | 'error';

/**
 * 对 AVPlayer 的薄封装,负责状态机推进(initialized -> prepared -> playing)
 * 和事件转发,让页面只需要关心回调而不用处理 AVPlayer 的生命周期细节。
 *
 * 注意:AVPlayer / picker 的具体事件名和方法签名会随 API Level 变化,
 * 集成前请对照你项目实际使用的 API Level 文档核对一遍。
 */
export class AudioService {
  private player: media.AVPlayer | null = null;
  // picker 返回的是 file://docs/... 文档 URI,AVPlayer 无法直接解析,
  // 需要先 openSync 成 fd 再以 fd:// 播放;fd 在播放期间必须保持打开。
  private currentFile: fileIo.File | null = null;
  private autoPlayOnReady = false;
  private volume = 1;
  private loadRequestId = 0;
  private lifecycleId = 0;
  private released = false;

  onStateChange: (state: PlayerState) => void = () => {};
  onTimeUpdate: (currentMs: number) => void = () => {};
  onDurationReady: (durationMs: number) => void = () => {};
  onCompleted: () => void = () => {};
  onError: (message: string) => void = () => {};

  async init(): Promise<boolean> {
    this.released = false;
    const lifecycleId = this.lifecycleId;
    try {
      const player = await media.createAVPlayer();
      if (this.released || lifecycleId !== this.lifecycleId) {
        await player.release();
        return false;
      }
      this.player = player;
      player.setVolume(this.volume);
    } catch (err) {
      const e = err as BusinessError;
      this.onError(`init failed: ${e.code}: ${e.message}`);
      return false;
    }

    this.player.on('stateChange', (state: string) => {
      const s = state as PlayerState;
      hilog.info(DOMAIN, 'AudioService', 'stateChange -> %{public}s', s);
      this.onStateChange(s);

      if (s === 'initialized' && this.player) {
        // url 设置完成后进入 initialized,这里推进到 prepared
        this.player.prepare().catch((err: BusinessError) => {
          this.onError(`${err.code}: ${err.message}`);
        });
      }
      if (s === 'prepared' && this.player) {
        this.onDurationReady(this.player.duration);
        if (this.autoPlayOnReady) {
          this.autoPlayOnReady = false;
          this.player.play().catch((err: BusinessError) => {
            this.onError(`${err.code}: ${err.message}`);
          });
        }
      }
      if (s === 'completed') {
        this.onCompleted();
      }
    });

    this.player.on('timeUpdate', (timeMs: number) => {
      this.onTimeUpdate(timeMs);
    });

    this.player.on('error', (err: BusinessError) => {
      hilog.error(DOMAIN, 'AudioService', 'AVPlayer error: %{public}s', `${err.code}: ${err.message}`);
      this.onError(`${err.code}: ${err.message}`);
    });
    return true;
  }

  /** 加载一个新的音频地址,默认加载完成后自动播放 */
  async load(uri: string, autoPlay: boolean = true): Promise<void> {
    const player = this.player;
    if (!player || this.released) {
      return;
    }
    const requestId = ++this.loadRequestId;
    this.autoPlayOnReady = autoPlay;
    try {
      await player.reset();
      if (requestId !== this.loadRequestId || this.released) {
        return;
      }
      if (this.currentFile) {
        fileIo.closeSync(this.currentFile);
        this.currentFile = null;
      }
      if (uri.startsWith('http://') || uri.startsWith('https://')) {
        player.url = uri;
        hilog.info(DOMAIN, 'AudioService', 'load remote audio');
        return;
      }
      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      if (requestId !== this.loadRequestId || this.released) {
        fileIo.closeSync(file);
        return;
      }
      this.currentFile = file;
      player.url = `fd://${file.fd}`;
      hilog.info(DOMAIN, 'AudioService', 'load ready, fd=%{public}d', this.currentFile.fd);
    } catch (err) {
      if (requestId !== this.loadRequestId || this.released) {
        return;
      }
      const e = err as BusinessError;
      hilog.error(DOMAIN, 'AudioService', 'load failed: %{public}s', `${e.code}: ${e.message}`);
      this.onError(`load failed: ${e.code}: ${e.message}`);
    }
  }

  play(): void {
    if (this.player) {
      this.player.play().catch((err: BusinessError) => {
        this.onError(`${err.code}: ${err.message}`);
      });
    }
  }

  pause(): void {
    if (this.player) {
      this.player.pause().catch((err: BusinessError) => {
        this.onError(`${err.code}: ${err.message}`);
      });
    }
  }

  /** 停止当前播放并释放当前文件句柄,但保留播放器实例供下一首使用。 */
  async stop(): Promise<void> {
    const player = this.player;
    if (!player || this.released) {
      return;
    }
    const requestId = ++this.loadRequestId;
    this.autoPlayOnReady = false;
    try {
      await player.reset();
    } catch (err) {
      if (requestId !== this.loadRequestId || this.released) {
        return;
      }
      const e = err as BusinessError;
      this.onError(`${e.code}: ${e.message}`);
    }
    if (requestId !== this.loadRequestId || this.released) {
      return;
    }
    if (this.currentFile) {
      try {
        fileIo.closeSync(this.currentFile);
      } catch (err) {
        const e = err as BusinessError;
        hilog.warn(DOMAIN, 'AudioService', 'close stopped fd failed: %{public}s', `${e.code}: ${e.message}`);
      }
      this.currentFile = null;
    }
  }

  /** ms: 目标进度(毫秒) */
  async seek(ms: number): Promise<void> {
    if (!this.player || this.released) {
      return;
    }
    try {
      await this.player.seek(ms);
    } catch (err) {
      const e = err as BusinessError;
      this.onError(`${e.code}: ${e.message}`);
    }
  }

  /** vol: 0.0 ~ 1.0 */
  setVolume(vol: number): void {
    this.volume = Math.max(0, Math.min(1, vol));
    this.player?.setVolume(this.volume);
  }

  get currentTime(): number {
    return this.player?.currentTime ?? 0;
  }

  get duration(): number {
    return this.player?.duration ?? 0;
  }

  /**
   * 读取一首歌的时长(毫秒),用于列表展示。会单独打开 fd 给元数据提取器,
   * 与播放用的 fd 互不干扰,读完后立即释放。
   */
  async fetchDurationMs(uri: string): Promise<number> {
    let file: fileIo.File | null = null;
    let extractor: media.AVMetadataExtractor | null = null;
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      extractor = await media.createAVMetadataExtractor();
      extractor.fdSrc = { fd: file.fd, offset: 0, length: -1 };
      const meta = await extractor.fetchMetadata();
      const raw = meta.duration;
      if (raw === undefined) {
        return -1;
      }
      const ms = Number(raw);
      return Number.isFinite(ms) && ms > 0 ? ms : -1;
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, 'AudioService', 'fetch duration failed: %{public}s', `${e.code}: ${e.message}`);
      return -1;
    } finally {
      if (extractor) {
        extractor.release().catch((): void => {
        });
      }
      if (file) {
        try {
          fileIo.closeSync(file);
        } catch (err) {
          const e = err as BusinessError;
          hilog.warn(DOMAIN, 'AudioService', 'close metadata fd failed: %{public}s', `${e.code}: ${e.message}`);
        }
      }
    }
  }

  /** 使用 SHA-256 计算文件内容摘要,用于播放列表去重。 */
  async hashFile(uri: string): Promise<string> {
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const md = cryptoFramework.createMd('SHA256');
      const chunkSize = 64 * 1024;
      const buffer = new ArrayBuffer(chunkSize);
      let offset = 0;
      let readLength = fileIo.readSync(file.fd, buffer, { offset, length: chunkSize });
      while (readLength > 0) {
        md.updateSync({ data: new Uint8Array(buffer, 0, readLength) });
        offset += readLength;
        await Promise.resolve();
        readLength = fileIo.readSync(file.fd, buffer, { offset, length: chunkSize });
      }
      const digest = md.digestSync().data;
      let hex = '';
      for (let i = 0; i < digest.length; i++) {
        hex += digest[i].toString(16).padStart(2, '0');
      }
      return hex;
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, 'AudioService', 'hash file failed: %{public}s', `${e.code}: ${e.message}`);
      return '';
    } finally {
      if (file) {
        try {
          fileIo.closeSync(file);
        } catch (err) {
          const e = err as BusinessError;
          hilog.warn(DOMAIN, 'AudioService', 'close hash fd failed: %{public}s', `${e.code}: ${e.message}`);
        }
      }
    }
  }

  async release(): Promise<void> {
    this.released = true;
    this.lifecycleId += 1;
    this.loadRequestId += 1;
    this.autoPlayOnReady = false;
    const player = this.player;
    this.player = null;
    if (player) {
      try {
        await player.release();
      } catch (err) {
        const e = err as BusinessError;
        this.onError(`release failed: ${e.code}: ${e.message}`);
      }
    }
    if (this.currentFile) {
      try {
        fileIo.closeSync(this.currentFile);
      } catch (err) {
        const e = err as BusinessError;
        hilog.error(DOMAIN, 'AudioService', 'close fd failed: %{public}s', `${e.code}: ${e.message}`);
      }
      this.currentFile = null;
    }
  }
}
