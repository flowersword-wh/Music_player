import { picker } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { AudioService, PlayerState } from '../common/AudioService';
import { BilibiliApiService, BilibiliSearchItem } from '../common/BilibiliApiService';
import { Track, ACCENT_PAIRS, fmtTime } from '../model/Track';
import { BlobCanvas } from '../view/BlobCanvas';
import { TrackRow } from '../view/TrackRow';

type PlayMode = '列表循环' | '单曲循环' | '随机播放';
type MainPage = '首页' | '搜索' | '统计';

interface PersistentTrackRecord {
  name: string;
  uri: string;
  duration: number;
  hash: string;
  accent: string;
  accent2: string;
}

@Entry
@Component
struct MusicPlayerPage {
  @State tracks: Track[] = [];
  @State currentIndex: number = -1;
  @State currentTrack: Track | null = null;
  @State isPlaying: boolean = false;
  @State currentTimeMs: number = 0;
  @State durationMs: number = 0;
  @State volume: number = 0.75;
  @State statusText: string = '空闲';
  @State audioReady: boolean = false;
  @State isLoading: boolean = false;
  @State isHashing: boolean = false;
  @State playMode: PlayMode = '列表循环';
  @State toastText: string = '';
  @State pressedNav: string = '';
  @State activePage: MainPage = '首页';
  @State searchKeyword: string = '';
  @State searchItems: BilibiliSearchItem[] = [];
  @State isSearching: boolean = false;
  @State searchStatus: string = '输入关键词开始搜索';
  @State downloadingBvid: string = '';
  @State playedDurationMs: number = 0;
  @State playCount: number = 0;
  @State completedCount: number = 0;
  @State appUsageMs: number = 0;

  private audioService: AudioService = new AudioService();
  private apiService: BilibiliApiService = new BilibiliApiService();
  private seeking: boolean = false;
  private lastUiTimeMs: number = -1;
  private lastDraggingTimeMs: number = -1;
  private seekRequestId: number = 0;
  private wasPlayingBeforeSeek: boolean = false;
  private toastTimer: number = -1;
  private usagePreferences: preferences.Preferences | null = null;
  private usageSessionStartMs: number = -1;
  private lastPlayerState: PlayerState = 'idle';
  private lastStatsTimeMs: number = -1;
  private playlistScroller: Scroller = new Scroller();
  private mainPages: MainPage[] = ['首页', '搜索', '统计'];
  // 随机播放使用“不重复抽取”的队列，而不是每次只排除当前歌曲。
  // 这样一轮播放中每首歌都会恰好出现一次，随后才开始下一轮。
  private shuffleQueue: number[] = [];
  private shuffleSignature: string = '';
  private loadGeneration: number = 0;
  private handledCompletionGeneration: number = -1;

  private centerCurrentTrack(): void {
    if (this.currentIndex < 0 || this.currentIndex >= this.tracks.length) {
      return;
    }
    setTimeout((): void => {
      this.playlistScroller.scrollToIndex(this.currentIndex + 1, true, ScrollAlign.CENTER);
    }, 0);
  }

  private updateVolumeFromTouch(event: TouchEvent): void {
    if (event.touches.length === 0) {
      return;
    }
    const y = event.touches[0].y;
    this.volume = Math.max(0, Math.min(1, 1 - (y / 188)));
    this.audioService.setVolume(this.volume);
  }

  private updateProgressFromTouch(event: TouchEvent): void {
    if (this.durationMs <= 0) {
      return;
    }
    if (event.type === TouchType.Down) {
      this.seeking = true;
      this.wasPlayingBeforeSeek = this.isPlaying;
      this.seekRequestId += 1;
    }
    if (event.type === TouchType.Cancel) {
      this.seeking = false;
      this.currentTimeMs = this.audioService.currentTime;
      this.lastUiTimeMs = this.currentTimeMs;
      return;
    }
    if (event.touches.length === 0) {
      return;
    }
    const y = Math.max(0, Math.min(188, event.touches[0].y));
    const targetMs = Math.max(0, Math.min(this.durationMs, (1 - y / 188) * this.durationMs));
    this.currentTimeMs = targetMs;
    this.lastUiTimeMs = targetMs;
    if (event.type === TouchType.Up) {
      const requestId = ++this.seekRequestId;
      this.audioService.seek(targetMs).then((): void => {
        if (requestId !== this.seekRequestId) {
          return;
        }
        // Keep the thumb at the user's chosen position until the player
        // reports its first post-seek time update.
        this.seeking = false;
        this.isPlaying = this.wasPlayingBeforeSeek;
        this.lastUiTimeMs = -1;
      });
    }
  }

  private updateNavPress(control: string, event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.pressedNav = control;
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.pressedNav = '';
    }
  }

  private totalKnownDuration(): number {
    return this.tracks.reduce((total: number, track: Track): number => {
      return total + (track.duration > 0 ? track.duration : 0);
    }, 0);
  }

  private async startUsageSession(): Promise<void> {
    try {
      const store = await preferences.getPreferences(getContext(this), 'music_player_statistics');
      this.usagePreferences = store;
      await this.restorePlaylist(store);
      await this.savePlaylist();
      const savedTotal = Number(await store.get('app_usage_ms', 0));
      const previousStart = Number(await store.get('app_usage_session_start_ms', 0));
      const now = Date.now();
      // If the previous process was killed before its lifecycle callback ran,
      // recover that unfinished session from its persisted start timestamp.
      const recoveredMs = previousStart > 0 && now >= previousStart ? now - previousStart : 0;
      this.appUsageMs = Math.max(0, savedTotal + recoveredMs);
      this.usageSessionStartMs = now;
      await store.put('app_usage_ms', this.appUsageMs);
      await store.put('app_usage_session_start_ms', now);
      await store.flush();
    } catch (_) {
      // Statistics must not prevent the player from starting if persistence
      // is temporarily unavailable.
      this.usagePreferences = null;
      this.usageSessionStartMs = Date.now();
    }
  }

  private async restorePlaylist(store: preferences.Preferences): Promise<void> {
    try {
      // Audio picker interaction can finish before preferences are ready.
      // Keep any tracks added during that small window instead of replacing
      // them with the old stored snapshot.
      if (this.tracks.length > 0) {
        return;
      }
      const raw = await store.get('persistent_playlist', '[]');
      if (typeof raw !== 'string') {
        return;
      }
      const savedTracks: PersistentTrackRecord[] = JSON.parse(raw) as PersistentTrackRecord[];
      const restored: Track[] = [];
      savedTracks.forEach((value: PersistentTrackRecord): void => {
        const name = String(value.name ?? '').trim();
        const uri = String(value.uri ?? '').trim();
        const hash = String(value.hash ?? '').trim();
        if (name.length === 0 || uri.length === 0 || hash.length === 0 || uri.startsWith('http')) {
          return;
        }
        const pair = ACCENT_PAIRS[restored.length % ACCENT_PAIRS.length];
        const track = new Track(name, uri, hash,
          String(value.accent ?? pair[0]), String(value.accent2 ?? pair[1]));
        const duration = Number(value.duration ?? -1);
        track.duration = Number.isFinite(duration) ? duration : -1;
        restored.push(track);
      });
      this.tracks = restored;
      if (this.audioReady && this.currentIndex === -1 && restored.length > 0) {
        this.loadTrack(0, false);
      }
    } catch (_) {
      // A corrupt preference must not prevent the player from opening.
    }
  }

  private async savePlaylist(): Promise<void> {
    if (!this.usagePreferences) {
      return;
    }
    const savedTracks = this.tracks
      .filter((track: Track): boolean => !track.uri.startsWith('http://') && !track.uri.startsWith('https://'))
      .map((track: Track): PersistentTrackRecord => ({
        name: track.name,
        uri: track.uri,
        duration: track.duration,
        hash: track.hash,
        accent: track.accent,
        accent2: track.accent2
      }));
    try {
      await this.usagePreferences.put('persistent_playlist', JSON.stringify(savedTracks));
      await this.usagePreferences.flush();
    } catch (_) {
      // Playlist persistence is best effort and must not interrupt playback.
    }
  }

  private async saveUsageSession(): Promise<void> {
    if (!this.usagePreferences || this.usageSessionStartMs < 0) {
      return;
    }
    const now = Date.now();
    const sessionMs = Math.max(0, now - this.usageSessionStartMs);
    try {
      const storedTotal = Number(await this.usagePreferences.get('app_usage_ms', this.appUsageMs));
      await this.usagePreferences.put('app_usage_ms', Math.max(storedTotal, this.appUsageMs) + sessionMs);
      await this.usagePreferences.put('app_usage_session_start_ms', 0);
      await this.usagePreferences.flush();
    } catch (_) {
      // Ignore persistence errors during teardown.
    }
    this.usageSessionStartMs = -1;
  }

  private async performSearch(): Promise<void> {
    const keyword = this.searchKeyword.trim();
    if (keyword.length === 0) {
      this.searchStatus = '请输入搜索关键词';
      return;
    }
    this.isSearching = true;
    this.searchStatus = '搜索中…';
    try {
      const result = await this.apiService.search(keyword);
      this.searchItems = result.items;
      this.searchStatus = result.items.length > 0 ? `找到 ${result.total} 个结果` : '没有找到相关视频';
    } catch (_) {
      this.searchStatus = '搜索失败，请确认 Python 后端已启动';
    } finally {
      this.isSearching = false;
    }
  }

  private async playSearchItem(item: BilibiliSearchItem): Promise<void> {
    if (!item.bvid) {
      this.showToast('该搜索结果没有可播放的视频编号');
      return;
    }
    const existingIndex = this.tracks.findIndex((track: Track): boolean => track.hash === `bilibili:${item.bvid}`);
    if (existingIndex >= 0) {
      this.activePage = '首页';
      this.loadTrack(existingIndex);
      return;
    }
    const pair = ACCENT_PAIRS[this.tracks.length % ACCENT_PAIRS.length];
    const track = new Track(item.title, this.apiService.getAudioStreamUrl(item.bvid), `bilibili:${item.bvid}`, pair[0], pair[1]);
    track.duration = this.parseSearchDuration(item.duration);
    this.tracks.push(track);
    this.savePlaylist();
    this.activePage = '首页';
    this.loadTrack(this.tracks.length - 1);
    this.showToast(`正在播放《${item.title}》`);
  }

  private parseSearchDuration(value: string): number {
    const parts = value.split(':');
    if (parts.length !== 2) {
      return -1;
    }
    const minutes = Number(parts[0]);
    const seconds = Number(parts[1]);
    return Number.isFinite(minutes) && Number.isFinite(seconds) ? (minutes * 60 + seconds) * 1000 : -1;
  }

  private async downloadSearchItem(item: BilibiliSearchItem): Promise<void> {
    if (!item.bvid || this.downloadingBvid.length > 0) {
      this.showToast(!item.bvid ? '该搜索结果没有可下载的视频编号' : '已有下载任务进行中');
      return;
    }
    this.downloadingBvid = item.bvid;
    try {
      const safeTitle = item.title.replace(/[\\/:*?"<>|]/g, '_').substring(0, 60) || item.bvid;
      // Let the system picker create a public document (normally under
      // Downloads) instead of writing into the application's private files.
      const fileName = `${safeTitle}_${item.bvid}.m4a`;
      const audioPicker = new picker.AudioViewPicker(getContext(this));
      const savedUris = await audioPicker.save({ newFileNames: [fileName] });
      if (!savedUris || savedUris.length === 0) {
        this.showToast('已取消保存');
        return;
      }
      const fileUri = savedUris[0];
      const bytes = await this.apiService.downloadAudio(item.bvid, fileUri);
      try {
        await this.apiService.createDownload({
          bvid: item.bvid,
          title: item.title,
          status: 'completed',
          progress: 100,
          local_path: fileUri,
          file_size: bytes
        });
      } catch (_) {
        // The local file is already saved; history recording should not turn
        // a successful download into a failure message.
      }
      const existingIndex = this.tracks.findIndex((track: Track): boolean => track.hash === `bilibili:${item.bvid}`);
      if (existingIndex >= 0) {
        // A track may have been played before it was saved. Promote that
        // entry to the local file instead of adding a duplicate.
        this.tracks[existingIndex].uri = fileUri;
        this.tracks[existingIndex].duration = this.parseSearchDuration(item.duration);
      } else {
        const pair = ACCENT_PAIRS[this.tracks.length % ACCENT_PAIRS.length];
        const savedTrack = new Track(item.title, fileUri, `bilibili:${item.bvid}`, pair[0], pair[1]);
        savedTrack.duration = this.parseSearchDuration(item.duration);
        this.tracks.push(savedTrack);
      }
      this.savePlaylist();
      this.showToast(`已保存《${item.title}》`);
    } catch (_) {
      this.showToast('下载失败，请检查后端和网络连接');
    } finally {
      this.downloadingBvid = '';
    }
  }

  @Builder
  private leftControlBars(): void {
    Row({ space: 24 }) {
      Column() {
        Text('PLAYBACK').fontSize(8).letterSpacing(1.2).fontColor('#85847D')
        Stack({ alignContent: Alignment.Bottom }) {
          Column().width(42).height(150).backgroundColor('#D5D2C9')
          Column().width(42).height(`${this.durationMs > 0 ? Math.max(2, this.currentTimeMs / this.durationMs * 100) : 2}%`).backgroundColor('#1F211F')
        }
        .width(42).height(150)
        .onTouch((event: TouchEvent): void => this.updateProgressFromTouch(event))
        Text(`${fmtTime(this.currentTimeMs)} / ${fmtTime(this.durationMs)}`).fontSize(8).fontColor('#77766F').margin({ top: 6 })
      }
      .alignItems(HorizontalAlign.Start)

      Column() {
        Text('OUTPUT').fontSize(8).letterSpacing(1.2).fontColor('#85847D')
        Stack({ alignContent: Alignment.Bottom }) {
          Column().width(42).height(150).backgroundColor('#D5D2C9')
          Column().width(42).height(`${Math.max(2, this.volume * 100)}%`).backgroundColor('#1F211F')
        }
        .width(42).height(150)
        .onTouch((event: TouchEvent): void => this.updateVolumeFromTouch(event))
        Text(Math.round(this.volume * 100).toString().padStart(3, '0')).fontSize(8).fontColor('#77766F').margin({ top: 6 })
      }
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .margin({ top: 18, bottom: 18 })
  }

  aboutToAppear(): void {
    this.startUsageSession();
    this.audioService.onStateChange = (state: PlayerState): void => {
      if (state === 'playing' && this.lastPlayerState !== 'playing') {
        this.playCount += 1;
      }
      if (state === 'completed' && this.lastPlayerState !== 'completed') {
        this.completedCount += 1;
      }
      this.lastPlayerState = state;
      this.isPlaying = !this.seeking && state === 'playing';
      this.isLoading = state === 'initialized' || state === 'prepared';
      if (state === 'playing' || state === 'paused' || state === 'completed' || state === 'error') {
        this.isLoading = false;
      }
      this.statusText = this.stateText(state);
    };
    this.audioService.onTimeUpdate = (ms: number): void => {
      if (this.isPlaying && this.lastStatsTimeMs >= 0) {
        const delta = ms - this.lastStatsTimeMs;
        if (delta > 0 && delta <= 2000) {
          this.playedDurationMs += delta;
        }
      }
      this.lastStatsTimeMs = ms;
      if (!this.seeking && !this.isLoading && (this.lastUiTimeMs < 0 || ms - this.lastUiTimeMs >= 300)) {
        this.currentTimeMs = ms;
        this.lastUiTimeMs = ms;
      }
    };
    this.audioService.onDurationReady = (ms: number): void => {
      this.durationMs = ms;
      if (this.currentTrack) {
        this.currentTrack.duration = ms;
        this.savePlaylist();
      }
    };
    this.audioService.onError = (): void => {
      this.isPlaying = false;
      this.isLoading = false;
      this.statusText = '播放失败';
      this.showToast('无法播放此音频文件');
    };
    this.audioService.onCompleted = (): void => {
      // Route completion directly. Waiting for another state/timer can race
      // with AVPlayer's completed -> reset transition and skip the mode.
      this.playCompletedTrack();
    };
    this.audioService.init().then((ready: boolean): void => {
      this.audioReady = ready;
      if (ready) {
        this.audioService.setVolume(this.volume);
        if (this.currentIndex === -1 && this.tracks.length > 0) {
          this.loadTrack(0, false);
        }
      } else {
        this.statusText = '播放器不可用';
        this.showToast('播放器初始化失败，请重试');
      }
    });
  }

  aboutToDisappear(): void {
    this.saveUsageSession();
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
    this.audioService.release();
  }

  private showToast(message: string): void {
    this.toastText = message;
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
    }
    this.toastTimer = setTimeout((): void => {
      this.toastText = '';
      this.toastTimer = -1;
    }, 2600) as number;
  }

  private cyclePlayMode(): void {
    const modes: PlayMode[] = ['列表循环', '单曲循环', '随机播放'];
    const index = modes.indexOf(this.playMode);
    this.playMode = modes[(index + 1) % modes.length];
    if (this.playMode === '随机播放') {
      this.resetShuffleQueue();
    }
    this.showToast(`播放模式：${this.playMode}`);
  }

  private stateText(state: PlayerState): string {
    switch (state) {
      case 'idle': return '空闲';
      case 'initialized': return '准备中';
      case 'prepared': return '就绪';
      case 'playing': return '播放中';
      case 'paused': return '已暂停';
      case 'stopped': return '已停止';
      case 'completed': return '播放完成';
      case 'released': return '空闲';
      case 'error': return '出错了';
      default: return '空闲';
    }
  }

  private async addFiles(): Promise<void> {
    if (!this.audioReady || this.isHashing) {
      this.statusText = '播放器准备中';
      return;
    }
    this.isHashing = true;
    try {
      const audioPicker = new picker.AudioViewPicker();
      const uris: string[] = await audioPicker.select();
      if (!uris || uris.length === 0) {
        return;
      }
      this.statusText = '检查重复中';
      this.showToast('正在检查音频是否重复…');
      const startLen = this.tracks.length;
      const addedTracks: Track[] = [];
      const addedUris: string[] = [];
      let duplicateCount = 0;
      let unreadableCount = 0;
      for (let i = 0; i < uris.length; i++) {
        const uri = uris[i];
        const hash = await this.audioService.hashFile(uri);
        if (hash.length === 0) {
          unreadableCount++;
          continue;
        }
        if (this.tracks.some((item: Track): boolean => item.hash === hash) ||
          addedTracks.some((item: Track): boolean => item.hash === hash)) {
          duplicateCount++;
          continue;
        }
        const rawName = decodeURIComponent(uri.split('/').pop() ?? `曲目 ${startLen + i + 1}`);
        const name = rawName.replace(/\.[^.]+$/, '');
        const pair = ACCENT_PAIRS[(startLen + addedTracks.length) % ACCENT_PAIRS.length];
        addedTracks.push(new Track(name, uri, hash, pair[0], pair[1]));
        addedUris.push(uri);
      }
      if (addedTracks.length === 0) {
        this.showToast(unreadableCount > 0 ? '无法读取所选音频' : '所选音频已在播放列表中');
        return;
      }
      addedTracks.forEach((track: Track): void => {
        this.tracks.push(track);
      });
      this.savePlaylist();
      if (this.currentIndex === -1) {
        this.loadTrack(startLen);
      }
      const duplicateText = duplicateCount > 0 ? `，跳过 ${duplicateCount} 首重复歌曲` : '';
      const unreadableText = unreadableCount > 0 ? `，跳过 ${unreadableCount} 首无法读取的音频` : '';
      this.showToast(`已添加 ${addedTracks.length} 首歌曲${duplicateText}${unreadableText}`);
      // 后台读取每首歌的时长,列表行会通过 @ObjectLink 自动刷新
      addedUris.forEach((uri: string, i: number): void => {
        const track = addedTracks[i];
        this.audioService.fetchDurationMs(uri).then((ms: number): void => {
          const currentIdx = this.tracks.indexOf(track);
          if (ms > 0 && currentIdx >= 0) {
            this.tracks[currentIdx].duration = ms;
            this.savePlaylist();
          }
        });
      });
    } catch (e) {
      this.statusText = '无法读取音频';
      this.showToast('选择音频失败，请检查文件权限');
    } finally {
      this.isHashing = false;
    }
  }

  private loadTrack(i: number, autoPlay: boolean = true): void {
    if (!this.audioReady || i < 0 || i >= this.tracks.length) {
      return;
    }
    this.loadGeneration += 1;
    this.currentIndex = i;
    this.currentTrack = this.tracks[i];
    this.currentTimeMs = 0;
    this.lastUiTimeMs = -1;
    this.lastStatsTimeMs = -1;
    this.durationMs = this.tracks[i].duration > 0 ? this.tracks[i].duration : 0;
    this.isLoading = true;
    this.isPlaying = false;
    this.statusText = '切换中';
    this.centerCurrentTrack();
    this.audioService.load(this.tracks[i].uri, autoPlay);
  }

  private togglePlay(): void {
    if (this.tracks.length === 0) {
      return;
    }
    if (this.currentIndex === -1) {
      this.loadTrack(0);
      return;
    }
    if (this.isPlaying) {
      this.audioService.pause();
    } else {
      this.audioService.play();
    }
  }

  private prev(): void {
    if (this.tracks.length === 0) {
      return;
    }
    let i = this.currentIndex;
    if (this.playMode === '随机播放' && this.tracks.length > 1) {
      // 随机模式没有“上一首”的列表位置，返回一首新的随机歌曲。
      i = this.nextShuffleIndex();
    } else if (this.playMode !== '单曲循环') {
      i = (this.currentIndex - 1 + this.tracks.length) % this.tracks.length;
    }
    // 单曲循环下 next/prev 都是“重新播放当前曲目”，不会离开当前歌曲。
    if (i < 0) {
      i = 0;
    }
    this.loadTrack(i);
  }

  private next(): void {
    if (this.tracks.length === 0) {
      return;
    }
    let i = this.currentIndex;
    if (this.playMode === '随机播放' && this.tracks.length > 1) {
      // 手动下一首与自动播放共用同一个随机队列，避免退化为顺序播放。
      i = this.nextShuffleIndex();
    } else if (this.playMode !== '单曲循环') {
      i = (this.currentIndex + 1) % this.tracks.length;
    }
    if (i < 0) {
      i = 0;
    }
    this.loadTrack(i);
  }

  private playlistSignature(): string {
    return this.tracks.map((track: Track): string => track.hash.length > 0 ? track.hash : track.uri).join('|');
  }

  private resetShuffleQueue(): void {
    this.shuffleQueue = [];
    this.shuffleSignature = this.playlistSignature();
    for (let i = 0; i < this.tracks.length; i++) {
      if (i !== this.currentIndex) {
        this.shuffleQueue.push(i);
      }
    }
    // Fisher-Yates：每轮随机排列一次，避免 while 随机抽样造成重复或偏差。
    for (let i = this.shuffleQueue.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      const value = this.shuffleQueue[i];
      this.shuffleQueue[i] = this.shuffleQueue[j];
      this.shuffleQueue[j] = value;
    }
  }

  private nextShuffleIndex(): number {
    const signature = this.playlistSignature();
    if (signature !== this.shuffleSignature || this.shuffleQueue.length === 0) {
      this.resetShuffleQueue();
    }
    if (this.shuffleQueue.length === 0) {
      return this.currentIndex;
    }
    return this.shuffleQueue.shift() ?? this.currentIndex;
  }

  private playCompletedTrack(): void {
    if (this.tracks.length === 0) {
      return;
    }
    // completed 事件在部分 API 版本中可能被投递两次；一次加载只处理一次。
    if (this.handledCompletionGeneration === this.loadGeneration) {
      return;
    }
    this.handledCompletionGeneration = this.loadGeneration;
    if (this.playMode === '单曲循环') {
      this.loadTrack(this.currentIndex);
      return;
    }
    if (this.playMode === '随机播放' && this.tracks.length > 1) {
      this.loadTrack(this.nextShuffleIndex());
      return;
    }
    // 列表循环到末尾时回到第一首；只有单曲循环才会留在当前歌曲。
    this.next();
  }

  private clearTracks(): void {
    this.audioService.stop();
    this.tracks = [];
    this.currentIndex = -1;
    this.currentTrack = null;
    this.currentTimeMs = 0;
    this.durationMs = 0;
    this.isPlaying = false;
    this.isLoading = false;
    this.statusText = '空闲';
    this.savePlaylist();
    this.showToast('播放列表已清空');
  }

  private removeTrack(i: number): void {
    const removedName = this.tracks[i]?.name ?? '歌曲';
    const wasCurrent = i === this.currentIndex;
    this.tracks.splice(i, 1);
    this.savePlaylist();
    if (this.tracks.length === 0) {
      this.audioService.stop();
      this.currentIndex = -1;
      this.currentTrack = null;
      this.currentTimeMs = 0;
      this.durationMs = 0;
      this.isPlaying = false;
    } else if (wasCurrent) {
      this.loadTrack(Math.min(i, this.tracks.length - 1));
    } else if (i < this.currentIndex) {
      this.currentIndex -= 1;
    }
    this.showToast(`已删除《${removedName}》`);
  }

  @Builder
  private searchPage(): void {
    Column() {
      Row() {
        Text('SEARCH')
          .fontSize(11)
          .letterSpacing(2)
          .fontColor('#85847D')
        Blank()
        Text('BILIBILI DISCOVERY')
          .fontSize(10)
          .letterSpacing(1.2)
          .fontColor('#85847D')
      }
      .width('100%')
      .margin({ bottom: 18 })

      Row({ space: 8 }) {
        TextInput({ placeholder: '搜索视频或音乐', text: this.searchKeyword })
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .backgroundColor('#E8E6DF')
          .onChange((value: string): void => {
            this.searchKeyword = value;
          })
        Button(this.isSearching ? '搜索中' : '搜索')
          .width(68)
          .height(40)
          .fontSize(11)
          .fontColor('#FBFAF7')
          .backgroundColor('#1F211F')
          .enabled(!this.isSearching)
          .onClick((): void => {
            this.performSearch();
          })
      }
      .width('100%')
      .margin({ bottom: 10 })

      Text(this.searchStatus)
        .fontSize(10)
        .fontColor('#85847D')
        .margin({ bottom: 12 })

      if (this.searchItems.length > 0) {
        List({ space: 0 }) {
          ForEach(this.searchItems, (item: BilibiliSearchItem) => {
            ListItem() {
              Row({ space: 10 }) {
                Text(item.title)
                  .fontSize(13)
                  .fontColor('#1F211F')
                  .layoutWeight(1)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Column() {
                  Text(item.author).fontSize(10).fontColor('#77766F')
                  Text(item.duration).fontSize(10).fontColor('#85847D').margin({ top: 4 })
                }
                .width(72)
                .alignItems(HorizontalAlign.End)
                Column({ space: 4 }) {
                  // Keep the label stable because List reuses row nodes while
                  // search results are refreshed. The shared download state
                  // is still reflected by the disabled/background styles.
                  Button('↓  SAVE')
                    .fontSize(9)
                    .fontWeight(FontWeight.Medium)
                    .height(28)
                    .padding({ left: 9, right: 9 })
                    .borderRadius(14)
                    .border({ width: 1, color: '#B7CBEA' })
                    .backgroundColor(this.downloadingBvid === item.bvid ? '#C8D8F0' : '#E8EEF8')
                    .fontColor('#174A9C')
                    .enabled(this.downloadingBvid.length === 0)
                    .onClick((): void => {
                      this.downloadSearchItem(item);
                    })
                }
                .width(62)
                .alignItems(HorizontalAlign.End)
              }
              .width('100%')
              .padding({ top: 12, bottom: 12, left: 8, right: 8 })
              .border({ width: { bottom: 1 }, color: '#D8D5CC' })
              .onClick((): void => {
                this.playSearchItem(item);
              })
            }
          }, (item: BilibiliSearchItem): string => `${item.bvid}_${item.aid}`)
        }
        .width('100%')
        .layoutWeight(1)
        // The page has 24vp horizontal padding. Extend only the result list
        // to the right edge so its scrollbar sits flush with the screen.
        .margin({ right: -24 })
        .scrollBar(BarState.Auto)
      } else {
        Column() {
          Text('BILIBILI')
            .fontSize(28)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1F211F')
          Text('SEARCH RESULTS WILL APPEAR HERE')
            .fontSize(10)
            .letterSpacing(1.1)
            .fontColor('#85847D')
            .margin({ top: 10 })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private statsPage(): void {
    Scroll() {
      Column({ space: 16 }) {
        Row() {
          Column() {
            Text('STATISTICS')
              .fontSize(11)
              .letterSpacing(2)
              .fontColor('#85847D')
            Text('PLAYBACK ARCHIVE')
              .fontSize(28)
              .fontWeight(FontWeight.Medium)
              .fontColor('#1F211F')
              .margin({ top: 8 })
          }
          .alignItems(HorizontalAlign.Start)
          Blank()
          Text('LOCAL / 2026')
            .fontSize(9)
            .letterSpacing(1.2)
            .fontColor('#85847D')
            .margin({ top: 4 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        Row({ space: 10 }) {
          Column() {
            Text(this.tracks.length.toString())
              .fontSize(27)
              .fontWeight(FontWeight.Medium)
              .fontColor('#174A9C')
            Text('TRACKS').fontSize(9).letterSpacing(1.2).fontColor('#77766F').margin({ top: 6 })
          }
          .layoutWeight(1)
          .padding({ top: 14, bottom: 14, left: 14, right: 14 })
          .backgroundColor('#E8EEF8')
          .borderRadius(6)

          Column() {
            Text(fmtTime(this.playedDurationMs))
              .fontSize(27)
              .fontWeight(FontWeight.Medium)
              .fontColor('#1F211F')
            Text('PLAY TIME').fontSize(9).letterSpacing(1.2).fontColor('#77766F').margin({ top: 6 })
          }
          .layoutWeight(1)
          .padding({ top: 14, bottom: 14, left: 14, right: 14 })
          .backgroundColor('#E8E6DF')
          .borderRadius(6)
        }
        .width('100%')

        Row({ space: 10 }) {
          Column() {
            Text(this.playCount.toString())
              .fontSize(27)
              .fontWeight(FontWeight.Medium)
              .fontColor('#1F211F')
            Text('PLAY COUNT').fontSize(9).letterSpacing(1.2).fontColor('#77766F').margin({ top: 6 })
          }
          .layoutWeight(1)
          .padding({ top: 14, bottom: 14, left: 14, right: 14 })
          .backgroundColor('#F0EFEA')
          .borderRadius(6)

          Column() {
            Text(fmtTime(this.appUsageMs))
              .fontSize(27)
              .fontWeight(FontWeight.Medium)
              .fontColor('#174A9C')
            Text('APP USAGE').fontSize(9).letterSpacing(1.2).fontColor('#77766F').margin({ top: 6 })
          }
          .layoutWeight(1)
          .padding({ top: 14, bottom: 14, left: 14, right: 14 })
          .backgroundColor('#E8EEF8')
          .borderRadius(6)
        }
        .width('100%')

        Row() {
          Text('CURRENTLY SELECTED')
            .fontSize(9)
            .letterSpacing(1.5)
            .fontColor('#85847D')
          Blank()
          Text(this.isPlaying ? 'PLAYING' : 'READY')
            .fontSize(9)
            .letterSpacing(1.2)
            .fontColor(this.isPlaying ? '#174A9C' : '#77766F')
          Text(`${this.completedCount} FINISHED`)
            .fontSize(9)
            .letterSpacing(1.1)
            .fontColor('#85847D')
            .margin({ left: 12 })
        }
        .width('100%')

        Row({ space: 12 }) {
          Stack() {
            BlobCanvas({
              accent: this.currentTrack?.accent ?? '#174A9C',
              accent2: this.currentTrack?.accent2 ?? '#3E7CFF',
              isPlaying: this.isPlaying,
            })
          }
          .width(86)
          .height(86)
          .border({ width: 1, color: '#D8D5CC' })
          .borderRadius(6)

          Column() {
            Text(this.currentTrack?.name ?? 'NO TRACK LOADED')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor('#1F211F')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.currentTrack ? `TRACK ${(this.currentIndex + 1).toString().padStart(2, '0')} / ${this.tracks.length.toString().padStart(2, '0')}` : 'IMPORT AUDIO TO BEGIN')
              .fontSize(9)
              .letterSpacing(1.1)
              .fontColor('#77766F')
              .margin({ top: 8 })
            Text(`${fmtTime(this.currentTimeMs)} / ${fmtTime(this.durationMs)}`)
              .fontSize(10)
              .fontColor('#174A9C')
              .margin({ top: 4 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding(14)
        .backgroundColor('#F0EFEA')
        .borderRadius(6)

        Row() {
          Text('RECENTLY ADDED')
            .fontSize(9)
            .letterSpacing(1.5)
            .fontColor('#85847D')
          Blank()
          Text(`${this.tracks.length} FILES`)
            .fontSize(9)
            .letterSpacing(1.1)
            .fontColor('#85847D')
        }
        .width('100%')

        Column() {
          if (this.tracks.length === 0) {
            Text('暂无已导入音频')
              .fontSize(12)
              .fontColor('#77766F')
              .padding(18)
          } else {
            ForEach(this.tracks.slice(0, 4), (track: Track, index: number) => {
              Row() {
                Text((index + 1).toString().padStart(2, '0'))
                  .fontSize(10)
                  .fontColor('#174A9C')
                  .width(28)
                Text(track.name)
                  .fontSize(12)
                  .fontColor('#1F211F')
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(fmtTime(track.duration))
                  .fontSize(10)
                  .fontColor('#77766F')
              }
              .width('100%')
              .padding({ top: 11, bottom: 11, left: 8, right: 8 })
              .border({ width: { bottom: 1 }, color: '#D8D5CC' })
            }, (track: Track): string => track.hash)
          }
        }
        .width('100%')
        .backgroundColor('#F0EFEA')
        .borderRadius(6)
      }
      .width('100%')
      .padding({ bottom: 8 })
    }
    .width('100%')
  }

  @Builder
  private bottomNavigation(): void {
    Row({ space: 6 }) {
      ForEach(this.mainPages, (page: MainPage) => {
        Button(page)
          .layoutWeight(1)
          .height(38)
          .fontSize(11)
          .fontWeight(this.activePage === page ? FontWeight.Medium : FontWeight.Regular)
          .fontColor(this.activePage === page ? '#FBFAF7' : '#77766F')
          .backgroundColor(this.activePage === page ? '#1F211F' : 'transparent')
          .borderRadius(4)
          .onClick((): void => {
            this.activePage = page;
          })
      }, (page: MainPage): string => page)
    }
    .width('100%')
    .height(52)
    .padding({ top: 7 })
    .border({ width: { top: 1 }, color: '#D8D5CC' })
  }

  @Builder
  private editorialLayout(): void {
    Column() {
      Row() {
        Text('PRISM / AUDIO ARCHIVE')
          .fontSize(12)
          .letterSpacing(1.8)
          .fontColor('#1F211F')
        Blank()
        Text('LOCAL PLAYBACK  /  2026')
          .fontSize(9)
          .letterSpacing(1.2)
          .fontColor('#85847D')
      }
      .width('100%')
      .padding({ bottom: 14 })
      .border({ width: { bottom: 1 }, color: '#D8D5CC' })

      if (this.activePage === '首页') {
      Row({ space: 30 }) {
        Column() {
          Row() {
            Text('01')
              .fontSize(10)
              .letterSpacing(1)
              .fontColor('#174A9C')
            Blank()
            Text(this.isPlaying ? 'PLAYING' : 'READY')
              .fontSize(9)
              .letterSpacing(1.4)
              .fontColor('#77766F')
          }
          .width('100%')
          .margin({ bottom: 0 })
          .height(0)
          .visibility(Visibility.Hidden)

          Stack() {
            BlobCanvas({
              accent: '#174A9C',
              accent2: '#174A9C',
              isPlaying: false,
            })
          }
          .width('100%')
          .aspectRatio(1)
          .border({ width: 1, color: '#D8D5CC' })
          .margin({ bottom: 16 })
          this.leftControlBars()
        }
        .width('46%')
        .alignItems(HorizontalAlign.Start)

        Column() {
          Text('CURRENT TRACK')
            .fontSize(9)
            .letterSpacing(2)
            .fontColor('#85847D')
            .margin({ bottom: 16 })
          Text(this.currentTrack?.name ?? 'SELECT AN AUDIO FILE')
            .fontSize(34)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1F211F')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.currentTrack ? `TRACK ${this.currentIndex + 1}  /  ${this.tracks.length}` : 'NO TRACK LOADED')
            .fontSize(11)
            .letterSpacing(1.2)
            .fontColor('#77766F')
            .margin({ top: 10, bottom: 22 })

          Row() {
            Text('FORMAT')
              .fontSize(9)
              .letterSpacing(1.2)
              .fontColor('#85847D')
            Blank()
            Text('LOCAL AUDIO  ·  STEREO')
              .fontSize(9)
              .letterSpacing(1)
              .fontColor('#77766F')
          }
          .width('100%')
          .padding({ bottom: 10 })
          .border({ width: { bottom: 1 }, color: '#D8D5CC' })

          if (this.tracks.length > 0) {
            List({ space: 0, scroller: this.playlistScroller }) {
              ListItem() {
                Row().height(91)
              }
              ForEach(this.tracks, (item: Track, index: number) => {
                ListItem() {
                  TrackRow({
                    track: item,
                    index: index,
                    isCurrent: item.hash === this.currentTrack?.hash,
                    onPlay: (i: number): void => this.loadTrack(i),
                    onRemove: (i: number): void => this.removeTrack(i),
                  })
                }
              }, (item: Track): string => item.hash)
              ListItem() {
                Row().height(91)
              }
            }
            .width('100%')
            .height(220)
            .margin({ top: 14, bottom: 8 })
            .scrollBar(BarState.Auto)
            .edgeEffect(EdgeEffect.Spring)
          } else {
            Text('NO AUDIO IN PLAYLIST  /  USE + ADD TO BEGIN')
              .fontSize(10)
              .letterSpacing(1.2)
              .fontColor('#85847D')
              .margin({ top: 18, bottom: 8 })
          }

          if (false) {
          Row() {
            Text(fmtTime(this.currentTimeMs)).fontSize(10).fontColor('#1F211F')
            Stack({ alignContent: Alignment.Bottom }) {
              Column().width(44).height(188).backgroundColor('#D5D2C9')
              Column().width(44).height(`${this.durationMs > 0 ? Math.max(2, this.currentTimeMs / this.durationMs * 100) : 2}%`).backgroundColor('#1F211F')
            }
            .width(44).height(188)
            .onTouch((event: TouchEvent): void => this.updateProgressFromTouch(event))
            Text(fmtTime(this.durationMs)).fontSize(10).fontColor('#1F211F')
          }
          .width('100%').justifyContent(FlexAlign.Center).margin({ top: 0, bottom: 0 })
          .visibility(Visibility.Hidden)
          .height(0)

          Row({ space: 18 }) {
            Column() {
              Text('OUTPUT')
                .fontSize(9)
                .letterSpacing(1.5)
                .fontColor('#85847D')
              Text(Math.round(this.volume * 100).toString().padStart(3, '0'))
                .fontSize(11)
                .letterSpacing(1)
                .fontColor('#1F211F')
            }
            .width(58)
            .alignItems(HorizontalAlign.Start)
            Stack({ alignContent: Alignment.Bottom }) {
              Column()
                .width(44)
                .height(188)
                .backgroundColor('#D5D2C9')
              Column()
                .width(44)
                .height(`${Math.max(2, this.volume * 100)}%`)
                .backgroundColor('#1F211F')
            }
            .width(44)
            .height(188)
            .onTouch((event: TouchEvent): void => {
              this.updateVolumeFromTouch(event);
            })
            Text('VOLUME')
              .fontSize(9)
              .letterSpacing(1.5)
              .fontColor('#85847D')
              .rotate({ angle: 90 })
          }
          .height(196)
          .margin({ bottom: 6 })
          .visibility(Visibility.Hidden)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.Center)
      .layoutWeight(1)
      .margin({ top: 24, bottom: 24 })

      Row() {
        Button() {
          Text('‹ PREV')
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .letterSpacing(1)
            .fontColor(this.pressedNav === 'prev' ? '#FBFAF7' : '#1F211F')
        }
        .width(92)
        .height(38)
        .borderRadius(2)
        .border({ width: 1, color: this.pressedNav === 'prev' ? '#174A9C' : '#D8D5CC' })
        .backgroundColor(this.pressedNav === 'prev' ? '#174A9C' : '#E8E6DF')
        .onTouch((event: TouchEvent): void => this.updateNavPress('prev', event))
        .onClick((): void => this.prev())
        Blank()
        Button() {
          Text(this.isLoading ? 'LOADING' : (this.isPlaying ? 'PAUSE' : 'PLAY'))
            .fontSize(10).letterSpacing(1).fontColor('#FBFAF7')
        }
        .width(86).height(38).borderRadius(2).backgroundColor('#1F211F')
        .enabled(this.tracks.length > 0 && !this.isLoading).onClick((): void => this.togglePlay())
        Blank()
        Button() {
          Text('NEXT ›')
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .letterSpacing(1)
            .fontColor(this.pressedNav === 'next' ? '#FBFAF7' : '#1F211F')
        }
        .width(92)
        .height(38)
        .borderRadius(2)
        .border({ width: 1, color: this.pressedNav === 'next' ? '#174A9C' : '#D8D5CC' })
        .backgroundColor(this.pressedNav === 'next' ? '#174A9C' : '#E8E6DF')
        .onTouch((event: TouchEvent): void => this.updateNavPress('next', event))
        .onClick((): void => this.next())
      }
      .width('100%').height(52).justifyContent(FlexAlign.SpaceBetween)
      .margin({ bottom: 18 })

      Row() {
        Text('PLAYLIST / INDEX')
          .fontSize(9)
          .letterSpacing(1.6)
          .fontColor('#85847D')
        Blank()
        Button(this.playMode)
          .fontSize(9)
          .height(26)
          .backgroundColor('#E8E6DF')
          .fontColor('#77766F')
          .onClick((): void => this.cyclePlayMode())
        Button('＋ ADD')
          .fontSize(9)
          .height(26)
          .margin({ left: 6 })
          .backgroundColor('#1F211F')
          .fontColor('#FBFAF7')
          .enabled(this.audioReady && !this.isHashing)
          .onClick((): void => {
            this.addFiles();
          })
      }
      .width('100%')
      .padding({ bottom: 8 })
      .border({ width: { bottom: 1 }, color: '#D8D5CC' })

      } else if (this.activePage === '搜索') {
        this.searchPage();
      } else {
        this.statsPage();
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 24, right: 24, top: 28, bottom: 28 })
    .backgroundColor('#FBFAF7')
  }

  build(): void {
    Column() {
      this.editorialLayout();
      this.bottomNavigation();
    }
    .width('100%')
    .height('100%')
  }
}
