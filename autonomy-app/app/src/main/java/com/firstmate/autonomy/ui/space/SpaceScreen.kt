package com.firstmate.autonomy.ui.space

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.firstmate.autonomy.domain.model.Goal
import com.firstmate.autonomy.domain.model.Moment
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Explore
import com.firstmate.autonomy.ui.common.UiStateContent
import com.firstmate.autonomy.ui.common.UiState
import com.firstmate.autonomy.ui.components.EmptyState
import java.time.LocalDate
import kotlin.math.hypot

/** How deep into the space view you currently are. */
private enum class Depth { SPACE, GALAXY, PLANET }

/**
 * The main view: everything you are keeping up, as a field of galaxies.
 *
 * Three depths, not four - space, one galaxy, one planet. A goal is a galaxy,
 * its particulars are the planets, and the moments you have named orbit those
 * as moons. Nothing here creates or edits anything; that stays on the ordinary
 * screens, because a canvas is a poor place to type.
 */
@Composable
fun SpaceRoute(
    onOpenGoal: (Long) -> Unit,
    modifier: Modifier = Modifier,
    viewModel: SpaceViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    SpaceScreen(
        state = state,
        today = viewModel.today,
        onToggleToday = viewModel::toggleToday,
        onOpenGoal = onOpenGoal,
        modifier = modifier,
    )
}

@Composable
fun SpaceScreen(
    state: UiState<List<Goal>>,
    today: LocalDate,
    onToggleToday: (Long, Boolean) -> Unit,
    onOpenGoal: (Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    UiStateContent(state = state, modifier = modifier.fillMaxSize()) { goals ->
        if (goals.isEmpty()) {
            EmptyState(
                icon = Icons.Outlined.Explore,
                title = "Your space is empty",
                message = "Every goal you set becomes a galaxy. Its particulars orbit it as " +
                    "planets, and the whole thing brightens or goes cold depending on how " +
                    "you treat it.",
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            SpaceField(
                goals = goals,
                today = today,
                onToggleToday = onToggleToday,
                onOpenGoal = onOpenGoal,
            )
        }
    }
}

@Composable
private fun SpaceField(
    goals: List<Goal>,
    today: LocalDate,
    onToggleToday: (Long, Boolean) -> Unit,
    onOpenGoal: (Long) -> Unit,
) {
    val renderer = remember { SpaceRenderer() }
    val density = LocalDensity.current.density
    SpaceRenderer.DENSITY = density

    var depth by remember { mutableStateOf(Depth.SPACE) }
    var goalIndex by remember { mutableStateOf(0) }
    var particularIndex by remember { mutableStateOf(0) }
    var openMoment by remember { mutableStateOf<Moment?>(null) }

    var camX by remember { mutableFloatStateOf(0f) }
    var camY by remember { mutableFloatStateOf(0f) }
    var zoom by remember { mutableFloatStateOf(0.55f) }
    var time by remember { mutableFloatStateOf(0f) }

    LaunchedEffect(Unit) {
        var start = 0L
        while (true) {
            androidx.compose.runtime.withFrameNanos { frame ->
                if (start == 0L) start = frame
                time = (frame - start) / 1_000_000_000f
            }
        }
    }
    // Bitmaps here are large; hand them back when the view leaves the screen.
    DisposableEffect(Unit) { onDispose { Sprites.trim() } }

    val safeGoal = goals.getOrNull(goalIndex.coerceIn(0, goals.lastIndex))

    Box(Modifier.fillMaxSize().background(SpacePalette.void)) {
        Canvas(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(depth, goals.size) {
                    detectTapGestures { offset ->
                        val hit = renderer.hits
                            .lastOrNull { hypot(offset.x - it.x, offset.y - it.y) <= it.radius }
                            ?: return@detectTapGestures
                        when (hit.kind) {
                            Hit.Kind.GALAXY -> { goalIndex = hit.index; depth = Depth.GALAXY }
                            Hit.Kind.EDGE_MARKER -> {
                                val (wx, wy) = renderer.goalPosition(hit.index)
                                camX = wx
                                camY = wy
                            }
                            Hit.Kind.PLANET -> { particularIndex = hit.index; depth = Depth.PLANET }
                            Hit.Kind.STAR -> safeGoal?.let { onOpenGoal(it.id) }
                            Hit.Kind.MOON -> openMoment = hit.moment
                        }
                    }
                }
                .pointerInput(depth) {
                    detectTransformGestures { _, pan, gestureZoom, _ ->
                        if (depth != Depth.SPACE) return@detectTransformGestures
                        camX -= pan.x / zoom
                        camY -= pan.y / zoom
                        zoom = (zoom * gestureZoom).coerceIn(0.14f, 1.7f)
                    }
                },
        ) {
            drawIntoCanvas { canvas ->
                val native = canvas.nativeCanvas
                when (depth) {
                    Depth.SPACE -> renderer.drawSpace(
                        native, size.width, size.height, goals,
                        Camera(camX, camY, zoom), today, time,
                    )
                    Depth.GALAXY -> safeGoal?.let { goal ->
                        renderer.drawGalaxyInterior(
                            native, size.width, size.height, goal, today, time,
                        )
                    }
                    Depth.PLANET -> safeGoal?.particulars
                        ?.getOrNull(particularIndex)
                        ?.let { particular ->
                            renderer.drawPlanetFocus(
                                native, size.width, size.height, particular, today, time,
                            )
                        }
                }
            }
        }

        SpaceChrome(
            depth = depth,
            goal = safeGoal,
            particularTitle = safeGoal?.particulars?.getOrNull(particularIndex)?.title,
            onUp = {
                depth = when (depth) {
                    Depth.PLANET -> Depth.GALAXY
                    else -> Depth.SPACE
                }
                openMoment = null
            },
        )

        if (depth == Depth.PLANET && safeGoal != null) {
            val particular = safeGoal.particulars.getOrNull(particularIndex)
            if (particular != null) {
                ParticularSheet(
                    goalTitle = safeGoal.title,
                    particular = particular,
                    today = today,
                    openMoment = openMoment,
                    onDismissMoment = { openMoment = null },
                    onToggleToday = { onToggleToday(particular.id, !particular.isCheckedOn(today)) },
                    onOpenGoal = { onOpenGoal(safeGoal.id) },
                    modifier = Modifier.align(Alignment.BottomCenter),
                )
            }
        }
    }
}

@Composable
private fun SpaceChrome(
    depth: Depth,
    goal: Goal?,
    particularTitle: String?,
    onUp: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(
            text = when (depth) {
                Depth.SPACE -> "Space"
                Depth.GALAXY -> "Space › ${goal?.title.orEmpty()}"
                Depth.PLANET -> "Space › ${goal?.title.orEmpty()} › ${particularTitle.orEmpty()}"
            },
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary,
        )
        if (depth != Depth.SPACE) {
            TextButton(onClick = onUp) { Text("Out") }
        }
    }
}

@Composable
private fun ParticularSheet(
    goalTitle: String,
    particular: com.firstmate.autonomy.domain.model.Particular,
    today: LocalDate,
    openMoment: Moment?,
    onDismissMoment: () -> Unit,
    onToggleToday: () -> Unit,
    onOpenGoal: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val condition = particular.condition(today)
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .padding(12.dp),
        shape = MaterialTheme.shapes.large,
        color = MaterialTheme.colorScheme.surface,
        tonalElevation = 3.dp,
    ) {
        Column(
            modifier = Modifier
                .padding(18.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (openMoment != null) {
                Text("Moment · ${particular.title}", style = MaterialTheme.typography.labelMedium)
                Text(openMoment.label, style = MaterialTheme.typography.headlineSmall)
                Text(
                    text = agoLabel(openMoment.ageDays(today)),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    text = "Named after the fact, so it records something that happened rather " +
                        "than a target you set. It stays in orbit whatever you do next.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                TextButton(onClick = onDismissMoment) { Text("Back to ${particular.title}") }
            } else {
                Text("Particular · $goalTitle", style = MaterialTheme.typography.labelMedium)
                Text(particular.title, style = MaterialTheme.typography.headlineSmall)
                Text(
                    text = "${condition.label} · ${particular.moments.size} " +
                        if (particular.moments.size == 1) "moon" else "moons",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.primary,
                )
                Text(
                    text = "${particular.daysIn(today, 7)} of the last 7 days · " +
                        "${particular.daysIn(today, 90)} of the last 90",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (particular.notes.isNotBlank()) {
                    Text(particular.notes, style = MaterialTheme.typography.bodyMedium)
                }
                Spacer(Modifier.height(2.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = onToggleToday) {
                        Text(if (particular.isCheckedOn(today)) "Done today" else "Mark today")
                    }
                    OutlinedButton(onClick = onOpenGoal) { Text("Edit goal") }
                }
            }
        }
    }
}

private fun agoLabel(days: Long): String = when {
    days < 14 -> "$days days ago"
    days < 60 -> "${days / 7} weeks ago"
    days < 400 -> "${days / 30} months ago"
    else -> "${days / 365} years ago"
}
