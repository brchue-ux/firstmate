package com.firstmate.autonomy.ui.goals

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.firstmate.autonomy.domain.model.GoalStatus
import com.firstmate.autonomy.domain.model.Particular
import com.firstmate.autonomy.domain.model.SurfaceKind
import com.firstmate.autonomy.ui.components.AutonomyCard
import com.firstmate.autonomy.ui.components.AutonomyMultilineField
import com.firstmate.autonomy.ui.components.AutonomyTextField
import com.firstmate.autonomy.ui.components.ConfirmDialog
import com.firstmate.autonomy.ui.components.SectionHeader
import java.time.LocalDate

/**
 * Creating and editing a goal, its particulars, and the moments named against
 * them. Deliberately an ordinary form - the space view is for looking, this is
 * for changing.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun GoalEditorRoute(
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
    viewModel: GoalEditorViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    var newParticular by remember { mutableStateOf("") }
    var newKind by remember { mutableStateOf(SurfaceKind.ROCK) }
    var confirmDelete by remember { mutableStateOf(false) }
    var momentFor by remember { mutableStateOf<Particular?>(null) }
    var momentLabel by remember { mutableStateOf("") }

    // A new goal closes the form as soon as it is saved; an existing one stays
    // open, because you are usually about to add particulars to it.
    LaunchedEffect(state.isSaved) {
        if (state.isSaved && state.isNew) onDone()
    }

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            AutonomyTextField(
                label = "Goal",
                value = state.title,
                onValueChange = viewModel::onTitleChange,
                placeholder = "Piano practice",
            )
        }
        item {
            AutonomyTextField(
                label = "Category",
                value = state.category,
                onValueChange = viewModel::onCategoryChange,
                placeholder = "Craft",
            )
        }
        item {
            AutonomyMultilineField(
                label = "Notes",
                value = state.notes,
                onValueChange = viewModel::onNotesChange,
            )
        }
        if (!state.isNew) {
            item {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    GoalStatus.entries.forEach { status ->
                        FilterChip(
                            selected = state.status == status,
                            onClick = { viewModel.onStatusChange(status) },
                            label = { Text(status.label) },
                        )
                    }
                }
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = viewModel::save, enabled = state.canSave) {
                    Text(if (state.isNew) "Create goal" else "Save")
                }
                if (!state.isNew) {
                    TextButton(onClick = { confirmDelete = true }) { Text("Delete") }
                }
            }
        }

        if (!state.isNew) {
            item { SectionHeader(title = "Particulars") }
            item {
                Text(
                    text = "The facets you actually tick. Each one becomes a planet, and its " +
                        "surface warms or freezes with how often you get to it.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            items(state.goal?.particulars.orEmpty(), key = { it.id }) { particular ->
                ParticularRow(
                    particular = particular,
                    today = viewModel.today,
                    onDelete = { viewModel.deleteParticular(particular.id) },
                    onNameMoment = { momentFor = particular; momentLabel = "" },
                )
            }
            item {
                AutonomyCard {
                    AutonomyTextField(
                        label = "Add a particular",
                        value = newParticular,
                        onValueChange = { newParticular = it },
                        placeholder = "Scales",
                    )
                    FlowRow(
                        modifier = Modifier.padding(top = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        SurfaceKind.entries.forEach { kind ->
                            FilterChip(
                                selected = newKind == kind,
                                onClick = { newKind = kind },
                                label = { Text(kind.name.lowercase().replaceFirstChar { it.uppercase() }) },
                            )
                        }
                    }
                    Button(
                        onClick = {
                            viewModel.addParticular(newParticular, newKind)
                            newParticular = ""
                        },
                        enabled = newParticular.isNotBlank(),
                        modifier = Modifier.padding(top = 10.dp),
                    ) { Text("Add") }
                }
            }
        }
    }

    if (confirmDelete) {
        ConfirmDialog(
            title = "Delete this goal?",
            message = "Its particulars and everything ticked against them go too. Decisions " +
                "you logged about it stay in the log.",
            confirmLabel = "Delete",
            onConfirm = {
                confirmDelete = false
                viewModel.deleteGoal(onDone)
            },
            onDismiss = { confirmDelete = false },
        )
    }

    momentFor?.let { particular ->
        ConfirmDialog(
            title = "Name a moment",
            message = "Something that actually happened on ${particular.title}. It becomes a " +
                "moon and stays in orbit whatever you do next.",
            confirmLabel = "Capture",
            onConfirm = {
                viewModel.nameMoment(particular.id, momentLabel.ifBlank { "A moment" })
                momentFor = null
            },
            onDismiss = { momentFor = null },
            content = {
                AutonomyTextField(
                    label = "What happened",
                    value = momentLabel,
                    onValueChange = { momentLabel = it },
                    placeholder = "Hands together at 80bpm",
                )
            },
        )
    }
}

@Composable
private fun ParticularRow(
    particular: Particular,
    today: LocalDate,
    onDelete: () -> Unit,
    onNameMoment: () -> Unit,
) {
    AutonomyCard(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Column(Modifier.weight(1f)) {
                Text(particular.title, style = MaterialTheme.typography.titleSmall)
                Text(
                    text = "${particular.condition(today).label} · " +
                        "${particular.moments.size} moons",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            TextButton(onClick = onNameMoment) { Text("Moment") }
            IconButton(onClick = onDelete) {
                Icon(Icons.Filled.Delete, contentDescription = "Delete ${particular.title}")
            }
        }
    }
}
