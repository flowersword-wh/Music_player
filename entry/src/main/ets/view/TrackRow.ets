import { Track, fmtTime } from '../model/Track';

/**
 * 播放列表单行:序号 + 歌名 + 时长 + 删除。
 * 用 @ObjectLink 持有 @Observed 的 Track,时长等字段变化时行会自动刷新。
 */
@Component
export struct TrackRow {
  @ObjectLink track: Track;
  @Prop index: number = 0;
  @Prop isCurrent: boolean = false;
  onPlay: (index: number) => void = () => {};
  onRemove: (index: number) => void = () => {};

  build(): void {
    Row() {
      Text(this.isCurrent ? '▶' : '')
        .fontSize(10)
        .fontColor(this.track.accent)
        .width(12)
      Text((this.index + 1).toString().padStart(2, '0'))
        .fontSize(11)
        .fontColor(this.isCurrent ? '#174A9C' : '#77766F')
        .width(20)
      Text(this.track.name)
        .fontSize(13)
        .fontColor(this.isCurrent ? '#174A9C' : '#1F211F')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.track.duration > 0 ? fmtTime(this.track.duration) : '读取中')
        .fontSize(11)
        .fontColor('#77766F')
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
    .borderRadius(0)
    .backgroundColor(this.isCurrent ? '#E8EEF8' : 'transparent')
    .border({
      width: { left: this.isCurrent ? 3 : 0 },
      color: this.track.accent,
    })
    .onClick((): void => {
      this.onPlay(this.index);
    })
  }
}
