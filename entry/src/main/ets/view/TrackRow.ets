import { Track, fmtTime } from '../model/Track';

/**
 * 播放列表单行:序号 + 歌名 + 时长 + 删除。
 * 用 @ObjectLink 持有 @Observed 的 Track,时长等字段变化时行会自动刷新。
 */
@Component
export struct TrackRow {
  @ObjectLink track: Track;
  index: number = 0;
  isCurrent: boolean = false;
  onPlay: (index: number) => void = () => {};
  onRemove: (index: number) => void = () => {};

  build(): void {
    Row() {
      Text(this.isCurrent ? '▶' : (this.index + 1).toString().padStart(2, '0'))
        .fontSize(11)
        .fontColor(this.isCurrent ? this.track.accent : '#B8ACDC')
        .width(20)
      Text(this.track.name)
        .fontSize(13)
        .fontColor(this.isCurrent ? this.track.accent : '#F5F0FF')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.track.duration > 0 ? fmtTime(this.track.duration) : '读取中')
        .fontSize(11)
        .fontColor('#B8ACDC')
        .margin({ right: 8 })
      Image($r('app.media.ic_close'))
        .width(14)
        .height(14)
        .onClick((): void => {
          this.onRemove(this.index);
        })
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(10)
    .backgroundColor(this.isCurrent ? 'rgba(255,255,255,0.1)' : 'transparent')
    .border({
      width: { left: this.isCurrent ? 3 : 0 },
      color: this.track.accent,
    })
    .onClick((): void => {
      this.onPlay(this.index);
    })
  }
}
