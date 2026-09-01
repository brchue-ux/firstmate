package com.firstmate.autonomy.ui.space

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import androidx.compose.ui.graphics.toArgb
import com.firstmate.autonomy.domain.model.Goal
import com.firstmate.autonomy.domain.model.Moment
import com.firstmate.autonomy.domain.model.Particular
import com.firstmate.autonomy.domain.model.SurfaceKind
import java.time.LocalDate
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

private const val TAU = (PI * 2).toFloat()

/** Something on screen that a tap can land on. */
data class Hit(
    val kind: Kind,
    val index: Int,
    val x: Float,
    val y: Float,
    val radius: Float,
    val moment: Moment? = null,
) {
    enum class Kind { GALAXY, EDGE_MARKER, STAR, PLANET, MOON }
}

/** Where the camera is looking, in world units. */
data class Camera(val x: Float, val y: Float, val zoom: Float)

/**
 * All the drawing for the space view.
 *
 * Kept as plain functions over an Android canvas rather than Compose draw
 * calls, because the whole look depends on additive blending and baked
 * bitmaps, which the platform canvas exposes directly.
 */
class SpaceRenderer {

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val addPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        xfermode = PorterDuffXfermode(PorterDuff.Mode.ADD)
    }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
    }
    private val monoPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        typeface = Typeface.MONOSPACE
    }

    val hits = mutableListOf<Hit>()

    /**
     * Goals are laid out on a golden-angle spiral, so they never form rows.
     *
     * These are density-independent units, like everything else in the sky.
     * A Compose canvas reports its size in raw pixels, so treating world units
     * as pixels drew the whole field at a third of its intended size on a
     * 3x screen - nine fingernail-sized smudges instead of a sky.
     */
    fun goalPosition(index: Int): Pair<Float, Float> {
        val angle = index * 2.39996f
        val radius = 240f * sqrt(index + 0.7f)
        return cos(angle) * radius to sin(angle) * radius
    }

    fun goalRadius(goal: Goal): Float =
        110f + goal.particulars.size * 16f + min(goal.momentCount, 20) * 2.5f

    // ----------------------------------------------------------------- space

    fun drawSpace(
        canvas: Canvas,
        width: Float,
        height: Float,
        goals: List<Goal>,
        camera: Camera,
        today: LocalDate,
        time: Float,
    ) {
        hits.clear()
        drawStarfield(canvas, width, height, camera, time)

        // One factor turns world units into screen pixels. Zoom alone is not
        // enough: the canvas is measured in pixels and the sky is written in dp.
        val scale = camera.zoom * DENSITY
        val margin = 40f * DENSITY

        val offscreen = mutableListOf<Triple<Int, Float, Float>>()
        goals.forEachIndexed { index, goal ->
            val (wx, wy) = goalPosition(index)
            val drift = sin(time * 0.11f + index) * 16f to cos(time * 0.09f + index * 1.3f) * 13f
            val sx = (wx + drift.first - camera.x) * scale + width / 2f
            val sy = (wy + drift.second - camera.y) * scale + height / 2f
            val radius = goalRadius(goal) * scale
            // A goal with nothing logged against it still has to be findable,
            // so the floor sits well clear of black. Liveliness separates a
            // worked goal from an untouched one; it does not hide either.
            val alpha = 0.40f + goal.liveliness(today) * 0.60f

            if (sx > -radius - margin && sx < width + radius + margin &&
                sy > -radius - margin && sy < height + radius + margin
            ) {
                drawGalaxy(canvas, goal, sx, sy, radius, alpha, time)
                if (radius > 26f * DENSITY) {
                    val fade = ((radius - 26f * DENSITY) / (34f * DENSITY)).coerceIn(0f, 1f)
                    textPaint.textSize = 12f * DENSITY
                    textPaint.color = Sprites.withAlpha(
                        if (goal.liveliness(today) < 0.3f) 0xFF7A8494.toInt() else 0xFFE8E6F5.toInt(),
                        fade,
                    )
                    canvas.drawText(goal.title, sx, sy + radius * 0.62f + 13f * DENSITY, textPaint)
                    monoPaint.textSize = 8.5f * DENSITY
                    monoPaint.color = Sprites.withAlpha(0xFF8B85AE.toInt(), fade)
                    canvas.drawText(
                        summaryFor(goal, today),
                        sx,
                        sy + radius * 0.62f + 27f * DENSITY,
                        monoPaint,
                    )
                }
                hits += Hit(Hit.Kind.GALAXY, index, sx, sy, max(30f * DENSITY, radius * 0.72f))
            } else {
                offscreen += Triple(index, sx, sy)
            }
        }
        drawEdgeMarkers(canvas, width, height, goals, offscreen)
    }

    private fun summaryFor(goal: Goal, today: LocalDate): String {
        if (goal.particulars.isEmpty()) return "NOTHING UNDER IT YET"
        if (goal.liveliness(today) < 0.08f) return "COLD"
        val warm = (goal.warmth(today) * 100).toInt()
        return "$warm% THIS WEEK · ${goal.particulars.size} PARTICULARS"
    }

    private fun drawStarfield(canvas: Canvas, width: Float, height: Float, camera: Camera, time: Float) {
        val rng = Rng(4242L)
        repeat(220) { i ->
            val x = (rng.next() - 0.5f) * 4200f
            val y = (rng.next() - 0.5f) * 4200f
            val z = 0.25f + rng.next() * 0.75f
            val phase = rng.next() * TAU
            val scale = camera.zoom * DENSITY
            val sx = (x - camera.x * z) * scale + width / 2f
            val sy = (y - camera.y * z) * scale + height / 2f
            if (sx < -4 || sx > width + 4 || sy < -4 || sy > height + 4) return@repeat
            val twinkle = 0.45f + 0.35f * sin(time * 1.4f + phase)
            paint.shader = null
            paint.color = Sprites.withAlpha(starColor(i), twinkle * z)
            canvas.drawCircle(sx, sy, (0.6f + rng.next() * 1.2f) * z * DENSITY, paint)
        }
    }

    private fun starColor(i: Int): Int = when (i % 5) {
        0 -> 0xFFFFF4E2.toInt()
        1 -> 0xFFFFE4C0.toInt()
        2 -> 0xFFDCE8FF.toInt()
        3 -> 0xFFFFFFFF.toInt()
        else -> 0xFFFFD6B0.toInt()
    }

    private fun drawGalaxy(
        canvas: Canvas,
        goal: Goal,
        sx: Float,
        sy: Float,
        radius: Float,
        alpha: Float,
        time: Float,
    ) {
        val form = GalaxyForm.forGoal(goal)
        val sprite = Sprites.galaxy(form)
        val colors = SpacePalette.galaxyColors(form.seed)
        val rotation = form.positionAngle + time * form.spin
        val diameter = radius * 2.05f

        canvas.save()
        canvas.translate(sx, sy)

        // A slower, larger copy underneath gives the disc an atmosphere.
        canvas.save()
        canvas.rotate(Math.toDegrees((rotation * 0.55f).toDouble()).toFloat())
        addPaint.shader = null
        addPaint.alpha = (alpha * 0.20f * 255).toInt().coerceIn(0, 255)
        drawSprite(canvas, sprite, diameter * 1.40f)
        canvas.restore()

        canvas.save()
        canvas.rotate(Math.toDegrees(rotation.toDouble()).toFloat())
        addPaint.alpha = (alpha * 255).toInt().coerceIn(0, 255)
        drawSprite(canvas, sprite, diameter)
        canvas.restore()

        val coreRadius = radius * 0.15f * if (form.type == GalaxyType.RING) 0.6f else 1f
        addPaint.alpha = 255
        addPaint.shader = RadialGradient(
            0f, 0f, max(coreRadius, 1f),
            intArrayOf(
                Sprites.withAlpha(0xFFFFF8E8.toInt(), 0.52f * alpha),
                Sprites.withAlpha(colors.core, 0.62f * alpha),
                0x00000000,
            ),
            floatArrayOf(0f, 0.34f, 1f),
            Shader.TileMode.CLAMP,
        )
        canvas.drawCircle(0f, 0f, coreRadius, addPaint)
        addPaint.shader = null
        canvas.restore()
    }

    private fun drawSprite(canvas: Canvas, sprite: Bitmap, diameter: Float) {
        val half = diameter / 2f
        canvas.drawBitmap(sprite, null, RectF(-half, -half, half, half), addPaint)
    }

    private fun drawEdgeMarkers(
        canvas: Canvas,
        width: Float,
        height: Float,
        goals: List<Goal>,
        offscreen: List<Triple<Int, Float, Float>>,
    ) {
        val margin = 26f * DENSITY
        val cx = width / 2f
        val cy = height / 2f
        offscreen.forEach { (index, sx, sy) ->
            val vx = sx - cx
            val vy = sy - cy
            val distance = max(hypot(vx, vy), 1f)
            val ux = vx / distance
            val uy = vy / distance
            val tx = if (ux != 0f) (width / 2f - margin) / abs(ux) else 1e9f
            val ty = if (uy != 0f) (height / 2f - margin) / abs(uy) else 1e9f
            val k = min(tx, ty)
            val ex = cx + ux * k
            val ey = cy + uy * k
            val proximity = (1f - (distance - max(width, height) / 2f) / 900f).coerceIn(0f, 1f)
            val dot = (2.5f + proximity * 5.5f) * DENSITY
            val halo = dot * 3.4f
            val core = SpacePalette.galaxyColors(GalaxyForm.forGoal(goals[index]).seed).core

            addPaint.shader = RadialGradient(
                ex, ey, halo,
                intArrayOf(
                    Sprites.withAlpha(core, 0.18f + proximity * 0.38f),
                    Sprites.withAlpha(core, 0.18f + proximity * 0.38f),
                    0x00000000,
                ),
                floatArrayOf(0f, 0.28f, 1f),
                Shader.TileMode.CLAMP,
            )
            addPaint.alpha = 255
            canvas.drawCircle(ex, ey, halo, addPaint)
            addPaint.shader = null
            addPaint.color = Sprites.withAlpha(0xFFFFF8EC.toInt(), 0.50f + proximity * 0.4f)
            canvas.drawCircle(ex, ey, dot * 0.42f, addPaint)

            textPaint.textSize = 9.5f * DENSITY
            textPaint.color = Sprites.withAlpha(0xFFC9C3E4.toInt(), 0.45f + proximity * 0.5f)
            captionAt(canvas, ex, ey, cx, cy, dot + 6f * DENSITY, listOf(goals[index].title to textPaint))
            hits += Hit(Hit.Kind.EDGE_MARKER, index, ex, ey, dot + 14f * DENSITY)
        }
    }

    // ---------------------------------------------------------------- galaxy

    fun drawGalaxyInterior(
        canvas: Canvas,
        width: Float,
        height: Float,
        goal: Goal,
        today: LocalDate,
        time: Float,
    ) {
        hits.clear()
        drawStarfield(canvas, width, height, Camera(0f, 0f, 1f), time)
        val cx = width / 2f
        val cy = height / 2f - 30f * DENSITY
        val squash = 0.58f

        paint.shader = null
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 1f
        paint.color = Sprites.withAlpha(0xFFFFFFFF.toInt(), 0.065f)
        goal.particulars.forEachIndexed { index, _ ->
            val r = orbitRadius(index, goal.particulars.size, width)
            canvas.drawOval(RectF(cx - r, cy - r * squash, cx + r, cy + r * squash), paint)
        }
        paint.style = Paint.Style.FILL

        drawStar(canvas, cx, cy, time)
        hits += Hit(Hit.Kind.STAR, -1, cx, cy, 34f * DENSITY)

        goal.particulars.forEachIndexed { index, particular ->
            val orbit = orbitRadius(index, goal.particulars.size, width)
            val angle = index * (TAU / max(goal.particulars.size, 1)) + 0.9f +
                time * (0.10f / (orbit / 90f)) * 0.42f
            val px = cx + cos(angle) * orbit
            val py = cy + sin(angle) * orbit * squash
            // The near half of the orbit is back-lit, so it shows a crescent.
            val lit = 0.62f - 0.30f * sin(angle)
            val size = planetSize(index, goal.particulars.size)

            drawMoonRing(canvas, particular, px, py, size, today, behind = true, time = time)
            drawMoons(canvas, particular, px, py, size, cx, cy, today, wide = true, behind = true, time = time)
            drawBody(canvas, particular.kind, particular.id, px, py, size, cx, cy, lit,
                particular.condition(today).recent, particular.condition(today).longRun)
            drawMoons(canvas, particular, px, py, size, cx, cy, today, wide = true, behind = false, time = time)
            drawMoonRing(canvas, particular, px, py, size, today, behind = false, time = time)

            val condition = particular.condition(today)
            textPaint.textSize = 10f * DENSITY
            textPaint.color = SpacePalette.label.toArgb()
            monoPaint.textSize = 7.5f * DENSITY
            monoPaint.color = when {
                condition.recent > 0.5f -> SpacePalette.warmLabel.toArgb()
                condition.recent > 0.05f -> SpacePalette.labelDim.toArgb()
                else -> SpacePalette.coldLabel.toArgb()
            }
            val moons = particular.moments.size
            val caption = condition.label.uppercase() +
                if (moons > 0) " · $moons ${if (moons == 1) "MOON" else "MOONS"}" else ""
            captionAt(
                canvas, px, py, cx, cy, size + 9f * DENSITY,
                listOf(particular.title to textPaint, caption to monoPaint),
                width, height,
            )
            hits += Hit(Hit.Kind.PLANET, index, px, py, size + 13f * DENSITY)
        }
    }

    private fun orbitRadius(index: Int, count: Int, width: Float): Float {
        val inner = width * 0.21f
        val outer = width * 0.43f
        if (count <= 1) return inner
        return inner + (outer - inner) * index / (count - 1).toFloat()
    }

    private fun planetSize(index: Int, count: Int): Float =
        (15.5f - index * (4f / max(count, 2))) * DENSITY

    private fun drawStar(canvas: Canvas, cx: Float, cy: Float, time: Float) {
        val radius = 23f * DENSITY * (1f + 0.045f * sin(time * 1.5f))
        addPaint.shader = RadialGradient(
            cx, cy, radius * 3.2f,
            intArrayOf(
                Sprites.withAlpha(0xFFFFECC4.toInt(), 0.62f),
                Sprites.withAlpha(0xFFFFBC70.toInt(), 0.17f),
                0x00000000,
            ),
            floatArrayOf(0f, 0.26f, 1f),
            Shader.TileMode.CLAMP,
        )
        addPaint.alpha = 255
        canvas.drawCircle(cx, cy, radius * 3.2f, addPaint)
        addPaint.shader = null
        canvas.save()
        canvas.clipPath(android.graphics.Path().apply {
            addCircle(cx, cy, radius, android.graphics.Path.Direction.CW)
        })
        paint.shader = null
        paint.alpha = 255
        canvas.drawBitmap(
            Sprites.star(), null,
            RectF(cx - radius, cy - radius, cx + radius, cy + radius), paint,
        )
        canvas.restore()
    }

    // ----------------------------------------------------------- planet focus

    /**
     * One particular, close in, with its whole moon system named.
     *
     * This is where the moons stop being dots: at this size the surface,
     * terminator and every moon's own phase are all legible, and the moments
     * you named read as text rather than as a count.
     */
    fun drawPlanetFocus(
        canvas: Canvas,
        width: Float,
        height: Float,
        particular: Particular,
        today: LocalDate,
        time: Float,
    ) {
        hits.clear()
        drawStarfield(canvas, width, height, Camera(0f, 0f, 1f), time)
        val cx = width / 2f
        val cy = height * 0.30f
        val radius = min(width, height) * 0.13f
        val sunX = cx - width * 0.42f
        val sunY = cy - height * 0.12f

        addPaint.shader = RadialGradient(
            sunX, sunY, width * 0.55f,
            intArrayOf(Sprites.withAlpha(0xFFFFE0AA.toInt(), 0.30f), 0x00000000),
            floatArrayOf(0f, 1f),
            Shader.TileMode.CLAMP,
        )
        addPaint.alpha = 255
        canvas.drawCircle(sunX, sunY, width * 0.55f, addPaint)
        addPaint.shader = null

        val condition = particular.condition(today)
        // Captions are held to the upper half: the readout sheet occupies the
        // bottom of the screen at this depth, and a moon name drawn behind it
        // is worse than one nudged inward.
        val bounds = width to (height * 0.52f)
        drawMoonRing(canvas, particular, cx, cy, radius, today, behind = true, time = time, wide = false)
        drawMoons(canvas, particular, cx, cy, radius, sunX, sunY, today,
            wide = false, behind = true, time = time, labelBounds = bounds)
        drawBody(canvas, particular.kind, particular.id, cx, cy, radius, sunX, sunY,
            0.74f, condition.recent, condition.longRun)
        drawMoons(canvas, particular, cx, cy, radius, sunX, sunY, today,
            wide = false, behind = false, time = time, labelBounds = bounds)
        drawMoonRing(canvas, particular, cx, cy, radius, today, behind = false, time = time, wide = false)
    }

    // ------------------------------------------------------------------ body

    /**
     * One body: baked surface, spherical shading, a soft terminator, frost from
     * the poles, warm seams through the night side, and an atmosphere whose
     * thickness is the long-run signal.
     */
    fun drawBody(
        canvas: Canvas,
        kind: SurfaceKind,
        seed: Long,
        px: Float,
        py: Float,
        radius: Float,
        sunX: Float,
        sunY: Float,
        lit: Float,
        recent: Float,
        longRun: Float,
    ) {
        val sprite = Sprites.planet(kind, seed)
        val colors = SpacePalette.surfaceColors(kind)
        val angle = atan2(sunY - py, sunX - px)

        colors.air?.let { air ->
            if (radius > 4f) {
                val outer = radius * (1.10f + longRun * 0.42f)
                val tinted = Sprites.blend(air, 0xFF96BEEB.toInt(), 1f - recent)
                addPaint.shader = RadialGradient(
                    px, py, outer,
                    intArrayOf(0x00000000, Sprites.withAlpha(tinted, 0.05f + longRun * 0.26f), 0x00000000),
                    floatArrayOf(0f, 0.38f, 1f),
                    Shader.TileMode.CLAMP,
                )
                addPaint.alpha = 255
                canvas.drawCircle(px, py, outer, addPaint)
                addPaint.shader = null
            }
        }

        canvas.save()
        canvas.clipPath(android.graphics.Path().apply {
            addCircle(px, py, radius, android.graphics.Path.Direction.CW)
        })
        paint.shader = null
        paint.alpha = 255
        paint.colorFilter = null
        canvas.drawBitmap(
            sprite.surface, null,
            RectF(px - radius, py - radius, px + radius, py + radius), paint,
        )

        // Frost creeps down from both poles as the long run thins out.
        val frost = 1f - longRun
        if (frost > 0.12f) {
            val capHeight = radius * (0.06f + frost * 0.92f)
            listOf(py - radius, py + radius).forEach { poleY ->
                paint.shader = RadialGradient(
                    px, poleY, max(capHeight, 1f),
                    intArrayOf(
                        Sprites.withAlpha(0xFFDEEEFA.toInt(), 0.20f + frost * 0.48f),
                        0x00000000,
                    ),
                    floatArrayOf(0f, 1f),
                    Shader.TileMode.CLAMP,
                )
                canvas.drawCircle(px, poleY, capHeight, paint)
            }
            paint.shader = null
        }

        // Surface temperature: the recent-activity signal.
        paint.color = if (recent > 0.5f) {
            Sprites.withAlpha(0xFFFF9240.toInt(), (recent - 0.5f) * 0.52f)
        } else {
            Sprites.withAlpha(0xFF84A6D4.toInt(), (0.5f - recent) * 0.62f)
        }
        canvas.drawCircle(px, py, radius, paint)

        // Spherical shading, from the sub-solar point outward.
        val sunOffsetX = cos(angle) * radius * 0.5f
        val sunOffsetY = sin(angle) * radius * 0.5f
        paint.shader = RadialGradient(
            px + sunOffsetX, py + sunOffsetY, radius * 1.9f,
            intArrayOf(
                Sprites.withAlpha(0xFFFFF6E4.toInt(), 0.34f),
                Sprites.withAlpha(0xFFFFEED6.toInt(), 0.05f),
                Sprites.withAlpha(0xFF060810.toInt(), 0.70f),
            ),
            floatArrayOf(0f, 0.30f, 1f),
            Shader.TileMode.CLAMP,
        )
        canvas.drawCircle(px, py, radius, paint)
        paint.shader = null

        // The phase, as a soft band across the disc rather than a hard cut.
        canvas.save()
        canvas.rotate(Math.toDegrees(angle.toDouble()).toFloat(), px, py)
        val edge = (1f - lit.coerceIn(0f, 1f)) * 2f - 1f
        val band = 0.16f + longRun * 0.14f
        paint.shader = LinearGradient(
            px + radius, py, px - radius, py,
            intArrayOf(0x00000000, Sprites.withAlpha(0xFF03050C.toInt(), 0.92f)),
            floatArrayOf(
                ((edge + 1f) / 2f - band).coerceIn(0f, 1f),
                ((edge + 1f) / 2f + band).coerceIn(0f, 1f),
            ),
            Shader.TileMode.CLAMP,
        )
        canvas.drawCircle(px, py, radius, paint)
        paint.shader = null
        canvas.restore()

        // Seams glow through the night side, so a warm body is never fully dark.
        if (recent > 0.06f && radius > 3f) {
            addPaint.shader = null
            addPaint.alpha = (min(0.85f, recent * 0.85f) * 255).toInt()
            canvas.drawBitmap(
                sprite.seams, null,
                RectF(px - radius, py - radius, px + radius, py + radius), addPaint,
            )
            addPaint.alpha = 255
        }
        canvas.restore()

        // Rim light on the sunward limb, brighter through thicker air.
        if (radius > 4f) {
            addPaint.shader = null
            addPaint.style = Paint.Style.STROKE
            addPaint.strokeWidth = max(0.7f, radius * (0.035f + longRun * 0.045f))
            addPaint.color = Sprites.withAlpha(0xFFFFF0D6.toInt(), min(0.45f, 0.10f + longRun * 0.34f))
            val sweep = 115f
            canvas.drawArc(
                RectF(px - radius * 0.98f, py - radius * 0.98f, px + radius * 0.98f, py + radius * 0.98f),
                Math.toDegrees(angle.toDouble()).toFloat() - sweep / 2f, sweep, false, addPaint,
            )
            addPaint.style = Paint.Style.FILL
        }
        // A thin airless body keeps a hard edge; a thick one blurs into its air.
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 1f
        paint.color = Sprites.withAlpha(0xFFB4C0DC.toInt(), (0.16f - longRun * 0.10f).coerceAtLeast(0.03f))
        canvas.drawCircle(px, py, radius, paint)
        paint.style = Paint.Style.FILL
    }

    // ----------------------------------------------------------------- moons

    /**
     * Moons are moments, oldest on the widest and slowest orbits. In the wide
     * view only the newest few are picked out; up close you see the system.
     */
    fun drawMoons(
        canvas: Canvas,
        particular: Particular,
        px: Float,
        py: Float,
        radius: Float,
        sunX: Float,
        sunY: Float,
        today: LocalDate,
        wide: Boolean,
        behind: Boolean,
        time: Float,
        labelBounds: Pair<Float, Float>? = null,
    ) {
        val moons = particular.momentsByAge.take(MOON_BODIES)
        val shown = if (wide) min(3, moons.size) else moons.size
        for (i in 0 until shown) {
            val moon = moons[i]
            val orbit = moonOrbit(moon.ageDays(today))
            val speed = 0.62f / Math.pow(orbit.toDouble(), 1.5).toFloat()
            val angle = i * 2.39996f + time * speed * 0.9f
            val far = sin(angle) < 0f
            if (far != behind) continue
            val distance = radius * if (wide) min(2.05f, orbit * 0.86f) else orbit * 0.98f
            val mx = px + cos(angle) * distance
            val my = py + sin(angle) * distance * 0.55f
            val size = max(1.8f * DENSITY, radius * (if (wide) 0.15f else 0.115f) * (1f - i * 0.035f))
            val lit = 0.5f + 0.44f * cos(angle - atan2(sunY - py, sunX - px))
            drawBody(canvas, SurfaceKind.BASALT, moon.id * 104_729L, mx, my, size, sunX, sunY, lit, 0.3f, 0.15f)

            if (!wide && i < 5 && labelBounds != null) {
                textPaint.textSize = 8f * DENSITY
                textPaint.color = Sprites.withAlpha(0xFFB2BAD6.toInt(), 0.34f + lit * 0.40f)
                captionAt(
                    canvas, mx, my, px, py, size + 9f * DENSITY,
                    listOf(moon.label to textPaint),
                    labelBounds.first, labelBounds.second,
                )
            }
            if (!behind) hits += Hit(Hit.Kind.MOON, i, mx, my, size + 8f * DENSITY, moment = moon)
        }
    }

    /**
     * Past a dozen moons the oldest stop being individuals and become a ring,
     * so a system running for years never turns into clutter.
     */
    fun drawMoonRing(
        canvas: Canvas,
        particular: Particular,
        px: Float,
        py: Float,
        radius: Float,
        today: LocalDate,
        behind: Boolean,
        time: Float,
        wide: Boolean = true,
    ) {
        val coalesced = particular.momentsByAge.drop(MOON_BODIES)
        if (coalesced.isEmpty()) return
        val outermost = coalesced.maxOf { moonOrbit(it.ageDays(today)) }
        val ringRadius = radius * outermost * if (wide) 0.86f else 0.98f
        val rng = Rng(particular.id * 31L + 11L)
        addPaint.shader = null
        repeat(220) {
            val angle = rng.next() * TAU + time * 0.05f
            if ((sin(angle) < 0f) != behind) return@repeat
            val rr = ringRadius * (0.975f + rng.next() * 0.055f)
            addPaint.color = Sprites.withAlpha(
                if (rng.next() < 0.3f) 0xFFFFE6C2.toInt() else 0xFFCBD4E6.toInt(),
                0.12f + rng.next() * 0.30f,
            )
            canvas.drawCircle(
                px + cos(angle) * rr,
                py + sin(angle) * rr * 0.55f,
                radius * 0.012f + rng.next() * radius * 0.016f,
                addPaint,
            )
        }
        addPaint.alpha = 255
    }

    private fun moonOrbit(ageDays: Long): Float = 1.42f + ln(1f + ageDays / 14f) * 0.40f

    // -------------------------------------------------------------- captions

    /**
     * A caption pinned to an orbiting body.
     *
     * The offset is a continuous function of direction, so the text slides
     * smoothly around the body as it goes round. Switching between left,
     * centre and right alignment - the obvious way to write this - makes the
     * label jump the instant the body crosses an axis, which is exactly what
     * the eye notices.
     */
    private fun captionAt(
        canvas: Canvas,
        bodyX: Float,
        bodyY: Float,
        anchorX: Float,
        anchorY: Float,
        pad: Float,
        lines: List<Pair<String, Paint>>,
        clipWidth: Float = Float.MAX_VALUE,
        clipHeight: Float = Float.MAX_VALUE,
    ) {
        val dx = bodyX - anchorX
        val dy = bodyY - anchorY
        val distance = max(hypot(dx, dy), 0.001f)
        val ux = dx / distance
        val uy = dy / distance
        val widest = lines.maxOf { (text, p) -> p.measureText(text) }
        val lineHeight = 11f * DENSITY
        val blockHeight = lines.size * lineHeight

        var centreX = bodyX + ux * (pad + widest / 2f)
        var centreY = bodyY + uy * (pad + blockHeight / 2f)
        if (clipWidth != Float.MAX_VALUE) {
            val marginX = widest / 2f + 6f * DENSITY
            centreX = centreX.coerceIn(marginX, max(marginX, clipWidth - marginX))
            val marginY = blockHeight / 2f + 6f * DENSITY
            centreY = centreY.coerceIn(marginY, max(marginY, clipHeight - marginY))
        }
        lines.forEachIndexed { index, (text, p) ->
            canvas.drawText(
                text,
                centreX,
                centreY - blockHeight / 2f + lineHeight * (index + 0.8f),
                p,
            )
        }
    }

    companion object {
        const val MOON_BODIES = 12

        /** Set once per composition from the device density. */
        var DENSITY: Float = 3f
    }
}
