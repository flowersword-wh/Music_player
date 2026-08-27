import { picker } from '@kit.CoreFileKit';
import { AudioService, PlayerState } from '../common/AudioService';
import { Track, ACCENT_PAIRS, fmtTime } from '../model/Track';
import { BlobCanvas } from '../view/BlobCanvas';
import { TrackRow } from '../view/TrackRow';

type PlayMode = '顺序播放' | '列表循环' | '单曲循环' | '随机播放';

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

  private audioService: AudioService = new AudioService();
  private seeking: boolean = false;
  private lastUiTimeMs: number = -1;
  private lastDraggingTimeMs: number = -1;
  private seekRequestId: number = 0;
  private wasPlayingBeforeSeek: boolean = false;
  private completionTimer: number = -1;
  private toastTimer: number = -1;
  private playlistScroller: Scroller = new Scroller();

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
    if (event.touches.length === 0 || this.durationMs <= 0) {
      return;
    }
    const y = event.touches[0].y;
    const targetMs = Math.max(0, Math.min(this.durationMs, (1 - y / 188) * this.durationMs));
    this.currentTimeMs = targetMs;
    this.lastUiTimeMs = targetMs;
    if (event.type === TouchType.Up) {
      this.audioService.seek(targetMs);
    }
  }

  private updateNavPress(control: string, event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.pressedNav = control;
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.pressedNav = '';
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
    this.audioService.onStateChange = (state: PlayerState): void => {
      this.isPlaying = !this.seeking && state === 'playing';
      this.isLoading = state === 'initialized' || state === 'prepared';
      if (state === 'playing' || state === 'paused' || state === 'completed' || state === 'error') {
        this.isLoading = false;
      }
      this.statusText = this.stateText(state);
    };
    this.audioService.onTimeUpdate = (ms: number): void => {
      if (!this.seeking && !this.isLoading && (this.lastUiTimeMs < 0 || ms - this.lastUiTimeMs >= 300)) {
        this.currentTimeMs = ms;
        this.lastUiTimeMs = ms;
      }
    };
    this.audioService.onDurationReady = (ms: number): void => {
      this.durationMs = ms;
      if (this.currentTrack) {
        this.currentTrack.duration = ms;
      }
    };
    this.audioService.onError = (): void => {
      this.isPlaying = false;
      this.isLoading = false;
      this.statusText = '播放失败';
      this.showToast('无法播放此音频文件');
    };
    this.audioService.onCompleted = (): void => {
      if (this.completionTimer >= 0 || this.isLoading) {
        return;
      }
      this.completionTimer = setTimeout((): void => {
        this.completionTimer = -1;
        if (!this.isLoading) {
          this.playCompletedTrack();
        }
      }, 0) as number;
    };
    this.audioService.init().then((ready: boolean): void => {
      this.audioReady = ready;
      if (ready) {
        this.audioService.setVolume(this.volume);
      } else {
        this.statusText = '播放器不可用';
        this.showToast('播放器初始化失败，请重试');
      }
    });
  }

  aboutToDisappear(): void {
    if (this.completionTimer >= 0) {
      clearTimeout(this.completionTimer);
      this.completionTimer = -1;
    }
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
    const modes: PlayMode[] = ['列表循环', '顺序播放', '单曲循环', '随机播放'];
    const index = modes.indexOf(this.playMode);
    this.playMode = modes[(index + 1) % modes.length];
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
    this.currentIndex = i;
    this.currentTrack = this.tracks[i];
    this.currentTimeMs = 0;
    this.lastUiTimeMs = -1;
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
    const i = (this.currentIndex - 1 + this.tracks.length) % this.tracks.length;
    this.loadTrack(i);
  }

  private next(): void {
    if (this.tracks.length === 0) {
      return;
    }
    const i = (this.currentIndex + 1) % this.tracks.length;
    this.loadTrack(i);
  }

  private playCompletedTrack(): void {
    if (this.tracks.length === 0) {
      return;
    }
    if (this.playMode === '单曲循环') {
      this.loadTrack(this.currentIndex);
      return;
    }
    if (this.playMode === '顺序播放' && this.currentIndex >= this.tracks.length - 1) {
      this.isPlaying = false;
      this.statusText = '播放完成';
      this.showToast('播放列表已播放完成');
      return;
    }
    if (this.playMode === '随机播放' && this.tracks.length > 1) {
      let randomIndex = this.currentIndex;
      while (randomIndex === this.currentIndex) {
        randomIndex = Math.floor(Math.random() * this.tracks.length);
      }
      this.loadTrack(randomIndex);
      return;
    }
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
    this.showToast('播放列表已清空');
  }

  private removeTrack(i: number): void {
    const removedName = this.tracks[i]?.name ?? '歌曲';
    const wasCurrent = i === this.currentIndex;
    this.tracks.splice(i, 1);
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

    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, top: 28, bottom: 28 })
    .backgroundColor('#FBFAF7')
  }

  build(): void {
    Column() {
      this.editorialLayout();
    }
    .width('100%')
    .height('100%')
  }
}
