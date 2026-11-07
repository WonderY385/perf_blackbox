@tool
class_name BBTimeline
extends RefCounted
## C3 时间线回放：把一次采集变成一条能拖、能看、能发给别人打开的时间线。
##
## 为什么不做「性能视频」：视频要编码、要播放器、还不能搜索某一帧的数值。
## 单文件 HTML（双击即开、零依赖、可发微信/邮件）+ 面板内可交互曲线，才是可用的载体。
##
## 降采样规则（关键）：桶宽 > 1 时同时保留 **max 与 median**。
## 只画均值会把掉帧抹平——掉帧恰恰是极值现象；只画 max 又看不出常态。

const DEFAULT_BUCKETS := 600


## 生成面板/HTML 共用的降采样数据
static func build_data(pack: Dictionary, buckets := DEFAULT_BUCKETS) -> Dictionary:
	var data: Dictionary = pack.get("data", {})
	var frames: PackedFloat64Array = data.get("frame_ms", PackedFloat64Array())
	var gpu: PackedFloat64Array = data.get("render_gpu_ms", PackedFloat64Array())
	var n := frames.size()
	var start_frame := int(pack.get("start_frame", 0))
	var out := {
		"schema_version": BBSchema.SCHEMA_VERSION,
		"total_frames": n,
		"start_frame": start_frame,
		"bucket_width": 1,
		"max": [],
		"median": [],
		"gpu_max": [],
		"from": [],
		"to": [],
		"events": _events(pack),
		"p95": 0.0,
	}
	if n == 0:
		return out
	var width := maxi(1, int(ceil(float(n) / float(maxi(1, buckets)))))
	var max_arr := []
	var med_arr := []
	var gpu_arr := []
	var from_arr := []
	var to_arr := []
	var i := 0
	while i < n:
		var j := mini(i + width, n)
		var seg := PackedFloat64Array()
		var gseg := PackedFloat64Array()
		for k in range(i, j):
			var v := frames[k]
			if v >= 0.0:
				seg.append(v)
				if k < gpu.size():
					var g := gpu[k]
					if g >= 0.0:
						gseg.append(g)
		max_arr.append(snappedf(BBStats.max_value(seg), 0.01))
		med_arr.append(snappedf(BBStats.percentile(seg, 0.5), 0.01))
		gpu_arr.append(snappedf(BBStats.max_value(gseg), 0.01) if gseg.size() > 0 else -1.0)
		from_arr.append(i)
		to_arr.append(j - 1)
		i = j
	out["bucket_width"] = width
	out["max"] = max_arr
	out["median"] = med_arr
	out["gpu_max"] = gpu_arr
	out["from"] = from_arr
	out["to"] = to_arr
	out["p95"] = snappedf(BBStats.percentile(frames, 0.95), 0.01)
	return out


static func build_html(pack: Dictionary, buckets := DEFAULT_BUCKETS) -> String:
	var d := build_data(pack, buckets)
	var payload := {
		"meta": {
			"tool": BBSchema.TOOL_NAME,
			"scene": _scene_of(pack),
			"start_frame": d["start_frame"],
			"total_frames": d["total_frames"],
			"bucket_width": d["bucket_width"],
			"p95": d["p95"],
			"created": Time.get_datetime_string_from_system(true),
		},
		"max": d["max"],
		"median": d["median"],
		"gpu_max": d["gpu_max"],
		"from": d["from"],
		"to": d["to"],
		"events": d["events"],
	}
	var json := JSON.stringify(payload)
	# 用 replace 而不是 % 格式化：模板里有 CSS 的 100%，会让格式化字符串解析失败
	return _HTML_TEMPLATE.replace("__BB_DATA__", json)


const _HTML_TEMPLATE := """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>Perf Blackbox 时间线</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; background:#14161a; color:#d7dce2; font:13px/1.5 -apple-system,"Segoe UI",Roboto,"Noto Sans SC",sans-serif; }
  header { padding:14px 18px 6px; }
  h1 { font-size:16px; margin:0 0 4px; font-weight:600; }
  .meta { color:#8b95a3; font-size:12px; }
  #wrap { padding:8px 18px 18px; }
  canvas { width:100%; height:420px; display:block; background:#191c21; border-radius:6px; }
  #tip { position:fixed; pointer-events:none; background:#0d0f12ee; border:1px solid #2c333d; border-radius:4px;
         padding:6px 8px; font-size:12px; white-space:pre; display:none; z-index:10; }
  .legend { display:flex; gap:18px; margin:8px 0 0; font-size:12px; color:#8b95a3; }
  .k { display:inline-block; width:14px; height:3px; vertical-align:middle; margin-right:5px; }
</style>
</head>
<body>
<header>
  <h1>Perf Blackbox — 帧时间线</h1>
  <div class="meta" id="meta"></div>
</header>
<div id="wrap">
  <canvas id="c"></canvas>
  <div class="legend">
    <span><i class="k" style="background:#e0575b"></i>每桶最大值（掉帧尖峰）</span>
    <span><i class="k" style="background:#4aa8ff"></i>每桶中位数（常态）</span>
    <span><i class="k" style="background:#ffd166"></i>事件窗口</span>
  </div>
</div>
<div id="tip"></div>
<script>
const DATA = __BB_DATA__;
const c = document.getElementById('c');
const ctx = c.getContext('2d');
const tip = document.getElementById('tip');
let hover = -1;

function metaText(m) {
  return `场景 ${m.scene || '(未记录)'} · 帧 ${m.start_frame}~${m.start_frame + m.total_frames - 1} · 共 ${m.total_frames} 帧 · 桶宽 ${m.bucket_width} · p95 ${m.p95} ms · 生成于 ${m.created}`;
}
document.getElementById('meta').textContent = metaText(DATA.meta);

function resize() {
  const r = c.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  c.width = Math.floor(r.width * dpr);
  c.height = Math.floor(r.height * dpr);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  draw();
}
window.addEventListener('resize', resize);

function yScale() {
  let mx = 16.7;
  for (const v of DATA.max) if (v > mx) mx = v;
  return mx * 1.1;
}

function draw() {
  const w = c.clientWidth, h = c.clientHeight;
  const padL = 46, padR = 10, padT = 10, padB = 24;
  const iw = w - padL - padR, ih = h - padT - padB;
  ctx.clearRect(0, 0, w, h);
  const ymax = yScale();
  const n = DATA.max.length;
  const xAt = i => padL + (n <= 1 ? 0 : (i / (n - 1)) * iw);
  const yAt = v => padT + ih - Math.min(v / ymax, 1) * ih;

  // 网格与刻度
  ctx.strokeStyle = '#232830'; ctx.fillStyle = '#7c8794'; ctx.font = '11px monospace'; ctx.lineWidth = 1;
  for (let i = 0; i <= 4; i++) {
    const v = ymax * i / 4;
    const y = yAt(v);
    ctx.beginPath(); ctx.moveTo(padL, y); ctx.lineTo(padL + iw, y); ctx.stroke();
    ctx.fillText(v.toFixed(1) + 'ms', 4, y + 4);
  }

  // 事件窗口
  for (const ev of DATA.events) {
    const a = ev.from_bucket, b = ev.to_bucket;
    if (a < 0 || b < 0) continue;
    ctx.fillStyle = 'rgba(255,209,102,0.10)';
    ctx.fillRect(xAt(a), padT, Math.max(2, xAt(b) - xAt(a)), ih);
    ctx.fillStyle = 'rgba(255,209,102,0.75)';
    ctx.fillText(ev.id, xAt(a) + 3, padT + 12);
  }

  // 中位数（细线）+ 最大值（粗线）
  ctx.lineWidth = 1.5; ctx.strokeStyle = '#4aa8ff'; ctx.beginPath();
  for (let i = 0; i < n; i++) { const x = xAt(i), y = yAt(DATA.median[i]); i ? ctx.lineTo(x, y) : ctx.moveTo(x, y); }
  ctx.stroke();
  ctx.lineWidth = 2.5; ctx.strokeStyle = '#e0575b'; ctx.beginPath();
  for (let i = 0; i < n; i++) { const x = xAt(i), y = yAt(DATA.max[i]); i ? ctx.lineTo(x, y) : ctx.moveTo(x, y); }
  ctx.stroke();

  // 悬停十字线
  if (hover >= 0 && hover < n) {
    ctx.strokeStyle = '#5b6673'; ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(xAt(hover), padT); ctx.lineTo(xAt(hover), padT + ih); ctx.stroke();
  }
}

function bucketAt(clientX) {
  const r = c.getBoundingClientRect();
  const padL = 46, padR = 10;
  const iw = r.width - padL - padR;
  const n = DATA.max.length;
  if (n <= 1) return 0;
  const t = (clientX - r.left - padL) / iw;
  return Math.max(0, Math.min(n - 1, Math.round(t * (n - 1))));
}

c.addEventListener('mousemove', e => {
  hover = bucketAt(e.clientX);
  draw();
  const f0 = DATA.meta.start_frame + DATA.from[hover];
  const f1 = DATA.meta.start_frame + DATA.to[hover];
  let txt = `帧 ${f0}~${f1}\\n最大值 ${DATA.max[hover].toFixed(2)} ms\\n中位数 ${DATA.median[hover].toFixed(2)} ms`;
  if (DATA.gpu_max[hover] >= 0) txt += `\\nGPU 最大 ${DATA.gpu_max[hover].toFixed(2)} ms`;
  for (const ev of DATA.events) {
    if (hover >= ev.from_bucket && hover <= ev.to_bucket) {
      txt += `\\n事件 ${ev.id}（${ev.severity}，${ev.ratio.toFixed(1)}×）`;
    }
  }
  tip.textContent = txt;
  tip.style.display = 'block';
  tip.style.left = (e.clientX + 14) + 'px';
  tip.style.top = (e.clientY + 14) + 'px';
});
c.addEventListener('mouseleave', () => { hover = -1; tip.style.display = 'none'; draw(); });

resize();
</script>
</body>
</html>
"""


static func _events(pack: Dictionary) -> Array:
	var out := []
	var evs: Array = pack.get("events", [])
	var start_frame := int(pack.get("start_frame", 0))
	var n := int(pack.get("frames", 0))
	var width := 1
	if n > 0:
		width = maxi(1, int(ceil(float(n) / float(DEFAULT_BUCKETS))))
	for ev in evs:
		if not (ev is Dictionary):
			continue
		var s := int(ev.get("start_frame", 0)) - start_frame
		var e := int(ev.get("end_frame", s)) - start_frame
		out.append({
			"id": String(ev.get("id", "evt")),
			"severity": String(ev.get("severity", "")),
			"ratio": float(ev.get("ratio", 1.0)),
			"peak_ms": float(ev.get("peak_ms", 0.0)),
			"peak_frame": int(ev.get("peak_frame", 0)),
			"from_bucket": clampi(s / width, 0, maxi(0, int(ceil(float(n) / float(width))) - 1)),
			"to_bucket": clampi(e / width, 0, maxi(0, int(ceil(float(n) / float(width))) - 1)),
		})
	return out


static func _scene_of(pack: Dictionary) -> String:
	var snap: Dictionary = pack.get("scene_snapshot", {})
	var scene := String(snap.get("scene_path", ""))
	if scene == "":
		scene = String(pack.get("manifest", {}).get("scene", ""))
	return scene
