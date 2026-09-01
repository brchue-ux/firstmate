package com.firstmate.autonomy.ui.space

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.util.LruCache
import com.firstmate.autonomy.domain.model.SurfaceKind
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * Everything drawn here is baked once into a bitmap and then blitted every
 * frame.
 *
 * A galaxy is several thousand additively blended particles; drawing those per
 * frame would be hopeless on a phone. Paying for the detail once at build time
 * and then drawing three bitmaps per galaxy per frame is what makes the detail
 * affordable at all. The cache is bounded, so a long list of goals cannot grow
 * the bitmap memory without limit.
 */
object Sprites {

    const val GALAXY_PX = 512
    const val PLANET_PX = 256
    const val STAR_PX = 192

    private const val TAU = (PI * 2).toFloat()

    /** Roughly 12 galaxies' worth of pixels. Beyond that the oldest are dropped. */
    private val galaxyCache = object : LruCache<Long, Bitmap>(12 * GALAXY_PX * GALAXY_PX * 4) {
        override fun sizeOf(key: Long, value: Bitmap) = value.byteCount
    }
    private val surfaceCache = object : LruCache<String, PlanetSprite>(
        24 * PLANET_PX * PLANET_PX * 4 * 2,
    ) {
        override fun sizeOf(key: String, value: PlanetSprite) =
            value.surface.byteCount + value.seams.byteCount
    }
    private var starSprite: Bitmap? = null

    /** A planet's baked surface, and the warm seams that glow through its night side. */
    class PlanetSprite(val surface: Bitmap, val seams: Bitmap)

    fun galaxy(form: GalaxyForm): Bitmap =
        galaxyCache[form.seed] ?: buildGalaxy(form).also { galaxyCache.put(form.seed, it) }

    fun planet(kind: SurfaceKind, seed: Long): PlanetSprite {
        val key = "${kind.name}:$seed"
        return surfaceCache[key] ?: buildPlanet(kind, seed).also { surfaceCache.put(key, it) }
    }

    fun star(): Bitmap = starSprite ?: buildStar().also { starSprite = it }

    /** Frees every cached bitmap. Called when the space view leaves the screen. */
    fun trim() {
        galaxyCache.evictAll()
        surfaceCache.evictAll()
        starSprite = null
    }

    // ---------------------------------------------------------------- galaxy

    private fun buildGalaxy(form: GalaxyForm): Bitmap {
        val size = GALAXY_PX
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val r = size / 2f
        val rng = Rng(form.seed)
        val colors = SpacePalette.galaxyColors(form.seed)
        val squash = 1f - form.inclination

        // A soft halo of old stars first, so the disc sits inside something.
        val halo = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = RadialGradient(
                r, r, r,
                intArrayOf(
                    withAlpha(blend(colors.core, colors.arm, 0.5f), 0.16f),
                    withAlpha(colors.arm, 0.05f),
                    0x00000000,
                ),
                floatArrayOf(0f, 0.55f, 1f),
                Shader.TileMode.CLAMP,
            )
        }
        canvas.save()
        canvas.scale(1f, max(squash, 0.22f), r, r)
        canvas.drawCircle(r, r, r, halo)
        canvas.restore()

        val ramp = Array(14) { i ->
            blend(colors.core, colors.arm, (i / 13f).let { it * it * 0.3f + it * 0.7f })
        }
        val add = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            xfermode = PorterDuffXfermode(PorterDuff.Mode.ADD)
        }

        val bar = form.bar * r
        val innerRadius = max(bar, r * 0.05f)

        repeat(form.particles) {
            val f = powf(rng.next(), form.concentration)
            var radius = f * r * 0.94f
            var theta: Float

            when (form.type) {
                GalaxyType.SPIRAL, GalaxyType.BARRED -> {
                    if (bar > 0f && radius < bar) {
                        val side = if (rng.next() < 0.5f) 0f else PI.toFloat()
                        theta = side + (rng.next() - 0.5f) * (0.42f * (1f - radius / bar) + 0.09f)
                    } else {
                        val arm = rng.int(max(form.arms, 1))
                        theta = armAngle(radius, innerRadius, form, arm) +
                            (rng.next() - 0.5f) * form.flocculence * (0.10f + f * 0.55f) * 2.4f
                        radius += (rng.next() - 0.5f) * r * 0.055f
                    }
                }
                GalaxyType.RING -> {
                    if (rng.next() < 0.14f) {
                        radius = powf(rng.next(), 2.2f) * r * 0.16f
                    } else {
                        radius = r * form.ringRadius +
                            (rng.next() + rng.next() + rng.next() - 1.5f) * r * 0.085f
                    }
                    theta = rng.next() * TAU
                }
                GalaxyType.LENTICULAR -> {
                    radius = min(r * 0.95f, -ln(1f - rng.next() * 0.985f) * r * 0.46f)
                    theta = rng.next() * TAU
                }
                GalaxyType.IRREGULAR -> {
                    val clump = rng.int(5)
                    theta = clump * 1.25f + (rng.next() - 0.5f) * 1.4f
                    radius = r * (0.10f + clump * 0.13f) + (rng.next() + rng.next() - 1f) * r * 0.22f
                }
                GalaxyType.ELLIPTICAL -> theta = rng.next() * TAU
            }

            val px = r + cos(theta) * radius
            val py = r + sin(theta) * radius * squash
            val index = ((abs(radius) / r) * 13.4f).toInt().coerceIn(0, 13)
            val blobSize = 5.5f + rng.next() * 9f + (1f - f) * 9f
            add.shader = null
            add.color = withAlpha(ramp[index], (0.10f + rng.next() * 0.14f) * (1f - f * 0.40f))
            canvas.drawCircle(px, py, blobSize / 2f, add)
        }

        // Dense bulge of old stars.
        repeat(140) {
            val a = rng.next() * TAU
            val rr = powf(rng.next(), 1.8f) * r * form.bulge
            add.color = withAlpha(colors.core, 0.10f + rng.next() * 0.13f)
            canvas.drawCircle(
                r + cos(a) * rr,
                r + sin(a) * rr * max(squash, 0.55f),
                8f + rng.next() * 13f,
                add,
            )
        }

        // Hydrogen knots, strung along the young arms.
        repeat(form.hiiRegions) {
            val hf = 0.22f + rng.next() * 0.70f
            var hr = hf * r * 0.9f
            val ha = when (form.type) {
                GalaxyType.SPIRAL, GalaxyType.BARRED ->
                    armAngle(hr, innerRadius, form, rng.int(max(form.arms, 1))) +
                        (rng.next() - 0.5f) * 0.30f
                GalaxyType.RING -> {
                    hr = r * form.ringRadius + (rng.next() - 0.5f) * r * 0.10f
                    rng.next() * TAU
                }
                else -> rng.next() * TAU
            }
            add.color = withAlpha(colors.hii, 0.16f + rng.next() * 0.26f)
            canvas.drawCircle(
                r + cos(ha) * hr,
                r + sin(ha) * hr * squash,
                3.5f + rng.next() * 6.5f,
                add,
            )
        }

        // Individually resolved stars.
        repeat(260) {
            val sf = powf(rng.next(), 0.5f)
            val sr = sf * r * 0.92f
            val sa = when (form.type) {
                GalaxyType.SPIRAL, GalaxyType.BARRED ->
                    armAngle(sr, innerRadius, form, rng.int(max(form.arms, 1))) +
                        (rng.next() - 0.5f) * 0.45f
                else -> rng.next() * TAU
            }
            val magnitude = rng.next()
            add.color = withAlpha(0xFFFFFBF4.toInt(), 0.35f + magnitude * 0.5f)
            canvas.drawCircle(
                r + cos(sa) * sr,
                r + sin(sa) * sr * squash,
                1.2f + magnitude * magnitude * 3f,
                add,
            )
        }

        // Dust, carved out rather than painted on. This is what stops a disc
        // reading as a smear.
        if (form.dust > 0f) {
            val cut = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_OUT)
                style = Paint.Style.STROKE
                strokeCap = Paint.Cap.ROUND
            }
            when (form.type) {
                GalaxyType.SPIRAL, GalaxyType.BARRED -> {
                    for (armIndex in 0 until max(form.arms, 1)) {
                        for (pass in 0..1) {
                            cut.color = withAlpha(
                                0xFF000000.toInt(),
                                (if (pass == 0) 0.34f else 0.18f) * form.dust,
                            )
                            cut.strokeWidth = (if (pass == 0) 7f else 14f) + rng.next() * 5f
                            val path = Path()
                            for (step in 0..72) {
                                val t = step / 72f
                                val rr = innerRadius + t * r * 0.86f
                                val th = armAngle(rr, innerRadius, form, armIndex) + 0.40f +
                                    pass * 0.10f
                                val x = r + cos(th) * rr
                                val y = r + sin(th) * rr * squash
                                if (step == 0) path.moveTo(x, y) else path.lineTo(x, y)
                            }
                            canvas.drawPath(path, cut)
                        }
                    }
                }
                GalaxyType.LENTICULAR, GalaxyType.RING -> {
                    cut.color = withAlpha(0xFF000000.toInt(), 0.45f * form.dust)
                    cut.strokeWidth = r * 0.06f
                    canvas.drawLine(r - r * 0.95f, r, r + r * 0.95f, r, cut)
                }
                GalaxyType.IRREGULAR -> {
                    repeat(9) {
                        cut.color = withAlpha(0xFF000000.toInt(), 0.22f * form.dust)
                        cut.strokeWidth = 6f + rng.next() * 12f
                        val ax = r + (rng.next() - 0.5f) * r * 1.1f
                        val ay = r + (rng.next() - 0.5f) * r * 0.9f
                        canvas.drawLine(
                            ax, ay,
                            ax + (rng.next() - 0.5f) * r * 0.7f,
                            ay + (rng.next() - 0.5f) * r * 0.5f,
                            cut,
                        )
                    }
                }
                GalaxyType.ELLIPTICAL -> Unit
            }
        }
        return bitmap
    }

    private fun armAngle(radius: Float, inner: Float, form: GalaxyForm, arm: Int): Float =
        ln(max(radius, inner) / inner) / form.pitch + arm * (TAU / max(form.arms, 1))

    // ---------------------------------------------------------------- planet

    private fun buildPlanet(kind: SurfaceKind, seed: Long): PlanetSprite {
        val size = PLANET_PX
        val surface = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(surface)
        val r = size / 2f
        val rng = Rng(seed)
        val c = SpacePalette.surfaceColors(kind)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)

        canvas.save()
        val clip = Path().apply { addCircle(r, r, r * 0.985f, Path.Direction.CW) }
        canvas.clipPath(clip)
        paint.color = c.base
        canvas.drawRect(0f, 0f, size.toFloat(), size.toFloat(), paint)

        when (c.style) {
            SpacePalette.SurfaceColors.Style.GAS -> {
                repeat(38) {
                    val y = rng.next() * size
                    val h = 3f + rng.next() * 20f
                    paint.color = withAlpha(
                        blend(c.base, if (rng.next() < 0.5f) c.dark else c.light, 0.3f + rng.next() * 0.65f),
                        0.12f + rng.next() * 0.28f,
                    )
                    canvas.drawRect(0f, y, size.toFloat(), y + h, paint)
                }
                val ox = r * (0.3f + rng.next() * 0.8f)
                val oy = r * (0.5f + rng.next() * 0.9f)
                paint.color = withAlpha(blend(c.dark, c.light, 0.25f), 0.5f)
                canvas.drawOval(RectF(ox - r * 0.20f, oy - r * 0.11f, ox + r * 0.20f, oy + r * 0.11f), paint)
            }
            SpacePalette.SurfaceColors.Style.ICE -> {
                repeat(240) {
                    val px = rng.next() * size
                    val py = rng.next() * size
                    val pr = 4f + rng.next() * 30f
                    paint.color = withAlpha(
                        if (rng.next() < 0.55f) c.light else c.dark,
                        0.04f + rng.next() * 0.13f,
                    )
                    canvas.drawOval(
                        RectF(px - pr, py - pr * (0.5f + rng.next() * 0.7f), px + pr, py + pr),
                        paint,
                    )
                }
                paint.style = Paint.Style.STROKE
                repeat(20) {
                    paint.color = withAlpha(c.dark, 0.16f + rng.next() * 0.16f)
                    paint.strokeWidth = 1f + rng.next() * 1.8f
                    var fx = rng.next() * size
                    var fy = rng.next() * size
                    val path = Path().apply { moveTo(fx, fy) }
                    repeat(5) {
                        fx += (rng.next() - 0.5f) * 60f
                        fy += (rng.next() - 0.5f) * 44f
                        path.lineTo(fx, fy)
                    }
                    canvas.drawPath(path, paint)
                }
                paint.style = Paint.Style.FILL
            }
            SpacePalette.SurfaceColors.Style.OCEAN -> {
                repeat(48) {
                    val cx = rng.next() * size
                    val cy = rng.next() * size
                    val cr = 8f + rng.next() * 40f
                    paint.color = withAlpha(blend(c.light, c.dark, rng.next() * 0.55f), 0.26f + rng.next() * 0.4f)
                    val path = Path()
                    for (a in 0 until 12) {
                        val ang = a / 12f * TAU
                        val rr = cr * (0.55f + rng.next() * 0.8f)
                        val x = cx + cos(ang) * rr
                        val y = cy + sin(ang) * rr * 0.7f
                        if (a == 0) path.moveTo(x, y) else path.lineTo(x, y)
                    }
                    path.close()
                    canvas.drawPath(path, paint)
                }
                repeat(80) {
                    paint.color = withAlpha(0xFFFFFFFF.toInt(), 0.14f)
                    val cx = rng.next() * size
                    val cy = rng.next() * size
                    val w = 8f + rng.next() * 36f
                    val h = 2f + rng.next() * 6f
                    canvas.drawOval(RectF(cx - w, cy - h, cx + w, cy + h), paint)
                }
            }
            SpacePalette.SurfaceColors.Style.ROCK -> {
                repeat(80) {
                    val px = rng.next() * size
                    val py = rng.next() * size
                    val w = 14f + rng.next() * 44f
                    val h = 10f + rng.next() * 30f
                    paint.color = withAlpha(
                        blend(c.base, if (rng.next() < 0.5f) c.dark else c.light, 0.4f + rng.next() * 0.6f),
                        0.03f + rng.next() * 0.09f,
                    )
                    canvas.drawOval(RectF(px - w, py - h, px + w, py + h), paint)
                }
                repeat(900) {
                    paint.color = withAlpha(if (rng.next() < 0.5f) c.dark else c.light, 0.03f + rng.next() * 0.08f)
                    canvas.drawCircle(rng.next() * size, rng.next() * size, 0.5f + rng.next() * 2.2f, paint)
                }
                // Craters, lit consistently from the upper left so the relief reads.
                repeat(200) {
                    val kx = rng.next() * size
                    val ky = rng.next() * size
                    val kr = 1.4f + powf(rng.next(), 3.2f) * 24f
                    paint.style = Paint.Style.FILL
                    paint.color = withAlpha(c.dark, 0.10f + rng.next() * 0.10f)
                    canvas.drawCircle(kx, ky, kr * 0.92f, paint)
                    paint.style = Paint.Style.STROKE
                    paint.strokeWidth = max(0.7f, kr * 0.20f)
                    val box = RectF(kx - kr * 0.94f, ky - kr * 0.94f, kx + kr * 0.94f, ky + kr * 0.94f)
                    paint.color = withAlpha(c.light, 0.16f + rng.next() * 0.20f)
                    canvas.drawArc(box, 200f, 140f, false, paint)
                    paint.color = withAlpha(c.dark, 0.18f + rng.next() * 0.20f)
                    canvas.drawArc(box, 20f, 140f, false, paint)
                    paint.style = Paint.Style.FILL
                }
            }
        }
        canvas.restore()

        // Warm seams, kept on their own layer so recent activity can dial them up.
        val seams = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val seamCanvas = Canvas(seams)
        seamCanvas.save()
        seamCanvas.clipPath(clip)
        val seamPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
        }
        val emberColors = intArrayOf(0xFFFF8A3C.toInt(), 0xFFFFB861.toInt(), 0xFFFF6A2A.toInt())
        repeat(9) {
            var jx = rng.next() * size
            var jy = rng.next() * size
            var dir = rng.next() * TAU
            repeat(9) {
                val nx = jx + cos(dir) * (8f + rng.next() * 22f)
                val ny = jy + sin(dir) * (8f + rng.next() * 22f)
                seamPaint.color = withAlpha(emberColors[rng.int(3)], 0.30f + rng.next() * 0.45f)
                seamPaint.strokeWidth = 0.9f + rng.next() * 2.4f
                seamCanvas.drawLine(jx, jy, nx, ny, seamPaint)
                jx = nx
                jy = ny
                dir += (rng.next() - 0.5f) * 1.5f
            }
        }
        seamPaint.style = Paint.Style.FILL
        repeat(50) {
            seamPaint.color = withAlpha(
                if (rng.next() < 0.5f) 0xFFFFC076.toInt() else 0xFFFF7A34.toInt(),
                0.20f + rng.next() * 0.35f,
            )
            seamCanvas.drawCircle(rng.next() * size, rng.next() * size, 0.8f + rng.next() * 3.2f, seamPaint)
        }
        seamCanvas.restore()

        return PlanetSprite(surface, seams)
    }

    // ------------------------------------------------------------------ star

    private fun buildStar(): Bitmap {
        val size = STAR_PX
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val r = size / 2f
        val rng = Rng(20_260_901L)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        canvas.save()
        canvas.clipPath(Path().apply { addCircle(r, r, r * 0.99f, Path.Direction.CW) })
        paint.color = 0xFFFFEBC0.toInt()
        canvas.drawRect(0f, 0f, size.toFloat(), size.toFloat(), paint)
        repeat(700) {
            val gr = 3f + rng.next() * 9f
            paint.color = withAlpha(
                if (rng.next() < 0.55f) 0xFFFFF8E4.toInt() else 0xFFF0B76A.toInt(),
                0.05f + rng.next() * 0.13f,
            )
            canvas.drawCircle(rng.next() * size, rng.next() * size, gr, paint)
        }
        repeat(5) {
            paint.color = withAlpha(0xFFC98A4C.toInt(), 0.14f + rng.next() * 0.12f)
            canvas.drawCircle(
                r + (rng.next() - 0.5f) * size * 0.7f,
                r + (rng.next() - 0.5f) * size * 0.7f,
                3f + rng.next() * 8f,
                paint,
            )
        }
        // Hot centre, darkened limb.
        paint.shader = RadialGradient(
            r, r, r,
            intArrayOf(
                withAlpha(0xFFFFFFFC.toInt(), 0.72f),
                withAlpha(0xFFFFF6DE.toInt(), 0.30f),
                withAlpha(0xFFFFCE8A.toInt(), 0f),
                withAlpha(0xFF9E5016.toInt(), 0.50f),
            ),
            floatArrayOf(0f, 0.34f, 0.75f, 1f),
            Shader.TileMode.CLAMP,
        )
        canvas.drawCircle(r, r, r, paint)
        canvas.restore()
        return bitmap
    }

    // ----------------------------------------------------------------- utils

    private fun powf(base: Float, exp: Float): Float =
        Math.pow(base.toDouble(), exp.toDouble()).toFloat()

    fun blend(a: Int, b: Int, f: Float): Int {
        val t = f.coerceIn(0f, 1f)
        fun channel(shift: Int): Int {
            val av = (a shr shift) and 0xFF
            val bv = (b shr shift) and 0xFF
            return (av + (bv - av) * t).toInt().coerceIn(0, 255)
        }
        return (0xFF shl 24) or (channel(16) shl 16) or (channel(8) shl 8) or channel(0)
    }

    fun withAlpha(color: Int, alpha: Float): Int =
        ((alpha.coerceIn(0f, 1f) * 255).toInt() shl 24) or (color and 0x00FFFFFF)
}
