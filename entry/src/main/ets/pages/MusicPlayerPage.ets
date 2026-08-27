import { picker } from '@kit.CoreFileKit';
import { AudioService, PlayerState } from '../common/AudioService';
import { Track, ACCENT_PAIRS, fmtTime } from '../model/Track';
import { BlobCanvas } from '../view/BlobCanvas';
import { TrackRow } from '../view/TrackRow';

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

  private audioService: AudioService = new AudioService();
  private seeking: boolean = false;

  aboutToAppear(): void {
    this.audioService.onStateChange = (state: PlayerState): void => {
      this.isPlaying = state === 'playing';
      this.statusText = this.stateText(state);
    };
    this.audioService.onTimeUpdate = (ms: number): void => {
      if (!this.seeking) {
        this.currentTimeMs = ms;
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
      this.statusText = '播放失败';
    };
    this.audioService.onCompleted = (): void => {
      if (this.tracks.length > 1) {
        this.next();
      } else {
        this.isPlaying = false;
      }
    };
    this.audioService.init().then((ready: boolean): void => {
      this.audioReady = ready;
      if (ready) {
        this.audioService.setVolume(this.volume);
      }
    });
  }

  aboutToDisappear(): void {
    this.audioService.release();
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
    if (!this.audioReady) {
      this.statusText = '播放器准备中';
      return;
    }
    try {
      const audioPicker = new picker.AudioViewPicker();
      const uris: string[] = await audioPicker.select();
      if (!uris || uris.length === 0) {
        return;
      }
      const startLen = this.tracks.length;
      uris.forEach((uri: string, i: number): void => {
        const rawName = decodeURIComponent(uri.split('/').pop() ?? `曲目 ${startLen + i + 1}`);
        const name = rawName.replace(/\.[^.]+$/, '');
        const pair = ACCENT_PAIRS[(startLen + i) % ACCENT_PAIRS.length];
        this.tracks.push(new Track(name, uri, pair[0], pair[1]));
      });
      if (this.currentIndex === -1) {
        this.loadTrack(startLen);
      }
      // 后台读取每首歌的时长,列表行会通过 @ObjectLink 自动刷新
      uris.forEach((uri: string, i: number): void => {
        const idx = startLen + i;
        const track = this.tracks[idx];
        this.audioService.fetchDurationMs(uri).then((ms: number): void => {
          const currentIdx = this.tracks.indexOf(track);
          if (ms > 0 && currentIdx >= 0) {
            this.tracks[currentIdx].duration = ms;
          }
        });
      });
    } catch (e) {
      // 用户取消选择或权限问题都会走到这里,静默处理即可
    }
  }

  private loadTrack(i: number, autoPlay: boolean = true): void {
    if (!this.audioReady || i < 0 || i >= this.tracks.length) {
      return;
    }
    this.currentIndex = i;
    this.currentTrack = this.tracks[i];
    this.currentTimeMs = 0;
    this.durationMs = this.tracks[i].duration > 0 ? this.tracks[i].duration : 0;
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

  private removeTrack(i: number): void {
    const wasCurrent = i === this.currentIndex;
    this.tracks.splice(i, 1);
    if (this.tracks.length === 0) {
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
  }

  build(): void {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        // 顶部状态行
        Row() {
          Row() {
            Circle({ width: 7, height: 7 })
              .fill(this.isPlaying ? '#2FE6D0' : '#B8ACDC')
              .margin({ right: 6 })
            Text(this.statusText.toUpperCase())
              .fontSize(11)
              .letterSpacing(1.5)
              .fontColor('#B8ACDC')
          }
          Blank()
          Text(fmtTime(this.durationMs))
            .fontSize(11)
            .fontColor('#B8ACDC')
        }
        .width('100%')
        .margin({ bottom: 16 })

        // 可视化封面
        Stack() {
          BlobCanvas({
            accent: this.currentTrack?.accent ?? '#FF3E9A',
            accent2: this.currentTrack?.accent2 ?? '#FF7A45',
            isPlaying: this.isPlaying,
          })

          if (this.tracks.length === 0) {
            Column() {
              Text('🎵')
                .fontSize(32)
                .margin({ bottom: 8 })
              Text('选择本地音频开始播放')
                .fontSize(14)
                .fontColor('#F5F0FF')
                .margin({ bottom: 4 })
              Text('支持多选')
                .fontSize(11)
                .fontColor('#B8ACDC')
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .backgroundColor('rgba(15,10,36,0.55)')
            .borderRadius(22)
            .onClick((): void => {
              this.addFiles();
            })
          }
        }
        .width('100%')
        .layoutWeight(2)
        .margin({ bottom: 18 })

        // 曲目信息
        Text(this.currentTrack?.name ?? '还没有歌曲')
          .fontSize(22)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F5F0FF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.currentTrack ? `曲目 ${this.currentIndex + 1} / ${this.tracks.length}` : '上传音频开始播放')
          .fontSize(13)
          .fontColor('#B8ACDC')
          .width('100%')
          .margin({ bottom: 16 })

        // 进度条
        Row() {
          Text(fmtTime(this.currentTimeMs)).fontSize(11).fontColor('#B8ACDC')
          Slider({
            value: this.durationMs > 0 ? (this.currentTimeMs / this.durationMs) * 100 : 0,
            min: 0, max: 100, step: 0.1,
          })
            .layoutWeight(1)
            .margin({ left: 10, right: 10 })
            .selectedColor(this.currentTrack?.accent ?? '#FF3E9A')
            .enabled(this.durationMs > 0)
            .onChange((value: number, mode: SliderChangeMode): void => {
              if (mode === SliderChangeMode.Moving) {
                this.seeking = true;
                this.currentTimeMs = (value / 100) * this.durationMs;
              } else if (mode === SliderChangeMode.End) {
                this.audioService.seek((value / 100) * this.durationMs);
                this.seeking = false;
              }
            })
          Text(fmtTime(this.durationMs)).fontSize(11).fontColor('#B8ACDC')
        }
        .width('100%')
        .margin({ bottom: 18 })

        // 播放控制
        Row({ space: 22 }) {
          Image($r('app.media.ic_prev'))
            .width(22).height(22)
            .opacity(this.tracks.length ? 1 : 0.3)
            .onClick((): void => this.prev())
          Button() {
            Image(this.isPlaying ? $r('app.media.ic_pause') : $r('app.media.ic_play'))
              .width(20).height(20)
          }
          .width(58).height(58)
          .borderRadius(29)
          .backgroundColor(this.currentTrack?.accent ?? '#FF3E9A')
          .enabled(this.tracks.length > 0)
          .onClick((): void => this.togglePlay())
          Image($r('app.media.ic_next'))
            .width(22).height(22)
            .opacity(this.tracks.length ? 1 : 0.3)
            .onClick((): void => this.next())
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .margin({ bottom: 18 })

        // 音量
        Row() {
          Image($r('app.media.ic_volume')).width(16).height(16)
          Slider({ value: this.volume * 100, min: 0, max: 100 })
            .layoutWeight(1)
            .margin({ left: 10 })
            .selectedColor(this.currentTrack?.accent ?? '#FF3E9A')
            .onChange((value: number): void => {
              this.volume = value / 100;
              this.audioService.setVolume(this.volume);
            })
        }
        .width('100%')
        .margin({ bottom: 16 })

        // 播放列表
        Row() {
          Text('播放列表').fontSize(11).letterSpacing(1).fontColor('#B8ACDC')
          Blank()
          Button('＋ 添加')
            .fontSize(11)
            .height(28)
            .backgroundColor('rgba(255,255,255,0.06)')
            .fontColor('#F5F0FF')
            .onClick((): void => {
              this.addFiles();
            })
        }
        .width('100%')
        .margin({ bottom: 8 })

        if (this.tracks.length === 0) {
          Text('播放列表是空的,上传几首歌吧')
            .fontSize(12)
            .fontColor('#B8ACDC')
            .margin({ top: 8 })
        } else {
          List({ space: 4 }) {
            ForEach(this.tracks, (item: Track, index: number) => {
              ListItem() {
                TrackRow({
                  track: item,
                  index: index,
                  isCurrent: index === this.currentIndex,
                  onPlay: (i: number): void => {
                    this.loadTrack(i);
                  },
                  onRemove: (i: number): void => {
                    this.removeTrack(i);
                  },
                })
              }
            }, (item: Track, index: number) => `${item.uri}-${index}`)
          }
          .width('100%')
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .padding(26)
      .borderRadius(28)
      .linearGradient({
        angle: 180,
        colors: [['#211840', 0], ['#2B2050', 1]],
      })
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor('#170F2E')
  }
}
