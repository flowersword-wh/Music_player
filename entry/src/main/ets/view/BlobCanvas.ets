/**
 * 纸张拼贴式专辑封面。
 * 使用少量平面图形完成错位、裁切和印刷标记,不创建动画定时器。
 */
@Component
export struct BlobCanvas {
  @Prop accent: string = '#174A9C';
  @Prop accent2: string = '#174A9C';
  @Prop isPlaying: boolean = false;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  private draw(): void {
    const ctx = this.context;
    const width = ctx.width;
    const height = ctx.height;
    if (width <= 0 || height <= 0) {
      return;
    }

    const paper = '#F3F1EB';
    const sheet = '#E5E2D9';
    const shadowPaper = '#D8D5CC';
    const ink = '#242522';
    const blue = '#174A9C';
    const minSide = Math.min(width, height);

    ctx.fillStyle = paper;
    ctx.fillRect(0, 0, width, height);

    // 背后的错位纸张,只用一条极淡的边缘制造深度。
    ctx.fillStyle = shadowPaper;
    ctx.fillRect(width * 0.15, height * 0.1, width * 0.7, height * 0.78);
    ctx.fillStyle = sheet;
    ctx.fillRect(width * 0.1, height * 0.07, width * 0.7, height * 0.78);

    // 一张偏移的深色唱片封面,形成拼贴的主要重量。
    ctx.fillStyle = ink;
    ctx.fillRect(width * 0.22, height * 0.2, width * 0.58, height * 0.62);

    // 唱片只露出右下部分,避免成为普通居中圆形。
    const recordX = width * 0.69;
    const recordY = height * 0.62;
    const recordRadius = minSide * 0.27;
    ctx.beginPath();
    ctx.arc(recordX, recordY, recordRadius, 0, Math.PI * 2);
    ctx.fillStyle = '#353632';
    ctx.fill();
    ctx.strokeStyle = 'rgba(243,241,235,0.22)';
    ctx.lineWidth = 1;
    for (let i = 1; i < 4; i++) {
      ctx.beginPath();
      ctx.arc(recordX, recordY, recordRadius * (i / 4), 0, Math.PI * 2);
      ctx.stroke();
    }
    ctx.beginPath();
    ctx.arc(recordX, recordY, recordRadius * 0.09, 0, Math.PI * 2);
    ctx.fillStyle = blue;
    ctx.fill();

    // 蓝色只做一张小型印刷标签,播放时变成长一点的校准标记。
    // 播放状态不改变封面构图,模式提示也不会让封面跳变。
    const labelWidth = minSide * 0.16;
    ctx.fillStyle = blue;
    ctx.fillRect(width * 0.28, height * 0.27, labelWidth, minSide * 0.035);

    // 印刷裁切线和定位十字。
    ctx.strokeStyle = 'rgba(36,37,34,0.35)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(width * 0.1, height * 0.88);
    ctx.lineTo(width * 0.38, height * 0.88);
    ctx.moveTo(width * 0.1, height * 0.86);
    ctx.lineTo(width * 0.1, height * 0.9);
    ctx.moveTo(width * 0.8, height * 0.12);
    ctx.lineTo(width * 0.9, height * 0.12);
    ctx.moveTo(width * 0.85, height * 0.09);
    ctx.lineTo(width * 0.85, height * 0.15);
    ctx.stroke();
  }

  build(): void {
    Canvas(this.context)
      .width('100%')
      .height('100%')
      .backgroundColor('#F3F1EB')
      .borderRadius(0)
      .onReady((): void => {
        this.draw();
      })
  }
}
