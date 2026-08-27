interface Particle {
  angle: number;
  radius: number;
  speed: number;
  size: number;
  offset: number;
}

function makeParticles(): Particle[] {
  const arr: Particle[] = [];
  for (let i = 0; i < 16; i++) {
    arr.push({
      angle: Math.random() * Math.PI * 2,
      radius: 0.3 + Math.random() * 0.5,
      speed: 0.2 + Math.random() * 0.4,
      size: 2 + Math.random() * 3,
      offset: Math.random() * Math.PI * 2,
    });
  }
  return arr;
}

/**
 * 变形专辑封面可视化组件。
 *
 * 说明:HarmonyOS 侧要拿到真实的音频频谱数据,需要用 AudioCapturer
 * 单独采集 PCM 再做 FFT,链路比 Web Audio 的 AnalyserNode 复杂不少。
 * 这里先用“播放中就产生一个带随机扰动的伪振幅”来驱动动画,视觉效果
 * 和之前网页版接近;如果后面想接真实频谱,可以在 AudioService 之外
 * 再加一个 AudioCapturer 管线,把算出的电平通过 level 传进来即可,
 * 这个组件本身不需要改。
 */
@Component
export struct BlobCanvas {
  @Prop accent: string = '#FF3E9A';
  @Prop accent2: string = '#FF7A45';
  @Prop isPlaying: boolean = false;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  private t: number = 0;
  private level: number = 0;
  private targetLevel: number = 0;
  private timerId: number = -1;
  private particles: Particle[] = makeParticles();

  private hexToRgb(hex: string): [number, number, number] {
    const v = parseInt(hex.replace('#', ''), 16);
    return [(v >> 16) & 255, (v >> 8) & 255, v & 255];
  }

  private startLoop(): void {
    this.timerId = setInterval((): void => {
      this.t += 0.016;
      // 播放时让目标振幅在 0.35~1 之间随机漂移,营造律动感;暂停时回落到 0
      if (this.isPlaying) {
        if (Math.random() < 0.08) {
          this.targetLevel = 0.35 + Math.random() * 0.65;
        }
      } else {
        this.targetLevel = 0;
      }
      this.level += (this.targetLevel - this.level) * 0.15;
      this.draw();
    }, 16) as number;
  }

  private draw(): void {
    const ctx = this.context;
    const w = ctx.width;
    const h = ctx.height;
    ctx.clearRect(0, 0, w, h);

    const c1 = this.hexToRgb(this.accent);
    const c2 = this.hexToRgb(this.accent2);
    const cx = w / 2;
    const cy = h / 2;
    const baseR = Math.min(w, h) * 0.28;
    const pulse = baseR * (1 + this.level * 0.35);

    // 背景辉光
    const glow = ctx.createRadialGradient(cx, cy, 0, cx, cy, Math.min(w, h) * 0.6);
    glow.addColorStop(0, `rgba(${c1[0]},${c1[1]},${c1[2]},0.18)`);
    glow.addColorStop(1, 'rgba(0,0,0,0)');
    ctx.fillStyle = glow;
    ctx.fillRect(0, 0, w, h);

    // 变形 blob
    const points = 48;
    ctx.beginPath();
    for (let i = 0; i <= points; i++) {
      const ang = (i / points) * Math.PI * 2;
      const noise = Math.sin(ang * 3 + this.t * 1.2) * 0.06 + Math.sin(ang * 5 - this.t * 0.8) * 0.04;
      const r = pulse * (1 + noise + this.level * 0.15);
      const x = cx + Math.cos(ang) * r;
      const y = cy + Math.sin(ang) * r;
      if (i === 0) {
        ctx.moveTo(x, y);
      } else {
        ctx.lineTo(x, y);
      }
    }
    ctx.closePath();

    const blobGrad = ctx.createLinearGradient(cx - pulse, cy - pulse, cx + pulse, cy + pulse);
    blobGrad.addColorStop(0, `rgba(${c1[0]},${c1[1]},${c1[2]},0.92)`);
    blobGrad.addColorStop(1, `rgba(${c2[0]},${c2[1]},${c2[2]},0.92)`);
    ctx.fillStyle = blobGrad;
    ctx.shadowColor = `rgba(${c1[0]},${c1[1]},${c1[2]},0.5)`;
    ctx.shadowBlur = 40;
    ctx.fill();
    ctx.shadowBlur = 0;

    // 内圈
    ctx.beginPath();
    ctx.arc(cx, cy, pulse * 0.5, 0, Math.PI * 2);
    ctx.strokeStyle = `rgba(255,255,255,${0.15 + this.level * 0.2})`;
    ctx.lineWidth = 1.5;
    ctx.stroke();

    // 漂浮的音符粒子
    for (const p of this.particles) {
      const ang = p.angle + this.t * p.speed;
      const rad = baseR * 1.6 * p.radius * (1 + Math.sin(this.t * 0.5 + p.offset) * 0.15);
      const x = cx + Math.cos(ang) * rad;
      const y = cy + Math.sin(ang + Math.sin(this.t * 0.3) * 0.3) * rad * 0.9;
      const alpha = this.isPlaying ? 0.3 + this.level * 0.5 : 0.15;
      ctx.beginPath();
      ctx.arc(x, y, p.size * (1 + this.level * 0.5), 0, Math.PI * 2);
      ctx.fillStyle = `rgba(${c2[0]},${c2[1]},${c2[2]},${alpha})`;
      ctx.fill();
    }
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
    }
  }

  build(): void {
    Canvas(this.context)
      .width('100%')
      .height('100%')
      .backgroundColor('#0F0A24')
      .borderRadius(22)
      .onReady((): void => {
        this.startLoop();
      })
  }
}
