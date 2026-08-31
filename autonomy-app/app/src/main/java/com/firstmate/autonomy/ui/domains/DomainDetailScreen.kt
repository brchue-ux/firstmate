package com.firstmate.autonomy.ui.domains

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.firstmate.autonomy.domain.model.DomainStatus
import com.firstmate.autonomy.domain.model.Milestone
import com.firstmate.autonomy.ui.common.UiState
import com.firstmate.autonomy.ui.common.UiStateContent
import com.firstmate.autonomy.ui.components.AutonomyCard
import com.firstmate.autonomy.ui.components.ChoiceChipRow
import com.firstmate.autonomy.ui.components.CollapsingScaffold
import com.firstmate.autonomy.ui.components.ConfettiEffect
import com.firstmate.autonomy.ui.components.ConfirmDialog
import com.firstmate.autonomy.ui.components.ExpandableContent
import com.firstmate.autonomy.ui.components.InlineEmptyState
import com.firstmate.autonomy.ui.components.LabelChip
import com.firstmate.autonomy.ui.components.ProgressRing
import com.firstmate.autonomy.ui.components.SectionHeader
import com.firstmate.autonomy.ui.components.rememberCelebration
import com.firstmate.autonomy.ui.preview.PreviewData
import com.firstmate.autonomy.ui.preview.ScreenPreviews
import com.firstmate.autonomy.ui.theme.AutonomyTheme
import kotlinx.coroutines.flow.collectLatest

/** One project: ring, milestones, notes and stage. */
@Composable
fun DomainDetailScreen(
    onNavigateBack: () -> Unit,
    onEditDomain: (Long) -> Unit,
    modifier: Modifier = Modifier,
    viewModel: DomainDetailViewModel = hiltViewModel(),
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val celebration = rememberCelebration()
    var celebrating by remember { mutableStateOf(false) }

    // Events, not state: a rotation must not replay the confetti.
    LaunchedEffect(viewModel) {
        viewModel.events.collectLatest { event ->
            celebration.tap()
            if (event is DomainDetailEvent.Completed) celebrating = true
        }
    }

    val state = uiState.dataOrNull
    LaunchedEffect(state?.isDeleted, uiState) {
        val gone = state?.isDeleted == true ||
            (uiState is UiState.Success && state?.domain == null)
        if (gone) onNavigateBack()
    }

    Box(modifier) {
        DomainDetailContent(
            uiState = uiState,
            onNavigateBack = onNavigateBack,
            onEditDomain = onEditDomain,
            onStatusChange = viewModel::setStatus,
            onMilestoneToggle = viewModel::setMilestoneCompleted,
            onMilestoneDelete = viewModel::deleteMilestone,
            onNewMilestoneTitleChange = viewModel::onNewMilestoneTitleChange,
            onAddMilestone = viewModel::addMilestone,
            onToggleNotes = viewModel::toggleNotes,
            onDeleteDomain = viewModel::deleteDomain,
        )
        ConfettiEffect(visible = celebrating, onFinished = { celebrating = false })
    }
}

@Composable
fun DomainDetailContent(
    uiState: UiState<DomainDetailState>,
    onNavigateBack: () -> Unit,
    onEditDomain: (Long) -> Unit,
    onStatusChange: (DomainStatus) -> Unit,
    onMilestoneToggle: (Milestone, Boolean) -> Unit,
    onMilestoneDelete: (Milestone) -> Unit,
    onNewMilestoneTitleChange: (String) -> Unit,
    onAddMilestone: () -> Unit,
    onToggleNotes: () -> Unit,
    onDeleteDomain: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var showDeleteDialog by remember { mutableStateOf(false) }
    val domain = uiState.dataOrNull?.domain

    CollapsingScaffold(
        modifier = modifier,
        title = domain?.title ?: "Project",
        subtitle = domain?.category,
        navigationIcon = {
            IconButton(onClick = onNavigateBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
            }
        },
        actions = {
            if (domain != null) {
                IconButton(onClick = { onEditDomain(domain.id) }) {
                    Icon(Icons.Outlined.Edit, contentDescription = "Edit project")
                }
                IconButton(onClick = { showDeleteDialog = true }) {
                    Icon(Icons.Outlined.Delete, contentDescription = "Delete project")
                }
            }
        },
    ) { innerPadding, _ ->
        UiStateContent(state = uiState, modifier = Modifier.padding(innerPadding)) { state ->
            val current = state.domain ?: return@UiStateContent
            val accent by animateColorAsState(
                targetValue = AutonomyTheme.accents.forStatus(current.status),
                label = "detailAccent",
            )

            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp)
                    .padding(bottom = 32.dp),
            ) {
                AutonomyCard {
                    Row(
                        modifier = Modifier.padding(20.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        ProgressRing(
                            progress = current.progress,
                            size = 104.dp,
                            strokeWidth = 12.dp,
                            color = accent,
                            contentDescriptionText = "Progress, " +
                                "${current.completedMilestoneCount} of " +
                                "${current.milestoneCount} milestones, " +
                                "${current.progressPercent} percent",
                        )
                        Spacer(Modifier.padding(horizontal = 10.dp))
                        Column(Modifier.weight(1f)) {
                            Text(
                                text = "${current.completedMilestoneCount} of " +
                                    "${current.milestoneCount}",
                                style = MaterialTheme.typography.headlineSmall,
                            )
                            Text(
                                text = "milestones complete",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            Spacer(Modifier.height(10.dp))
                            LabelChip(current.category)
                        }
                    }
                }

                Spacer(Modifier.height(24.dp))
                ChoiceChipRow(
                    label = "Status",
                    options = DomainStatus.entries,
                    selected = current.status,
                    onSelect = onStatusChange,
                    optionLabel = { it.label },
                )

                Spacer(Modifier.height(28.dp))
                SectionHeader(title = "Milestones")
                if (current.milestones.isEmpty()) {
                    InlineEmptyState(
                        "No milestones yet. Break the project into steps small enough to " +
                            "tick off in one sitting.",
                    )
                } else {
                    current.milestones.forEach { milestone ->
                        MilestoneRow(
                            milestone = milestone,
                            accent = accent,
                            onToggle = { checked -> onMilestoneToggle(milestone, checked) },
                            onDelete = { onMilestoneDelete(milestone) },
                        )
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    }
                }
                Spacer(Modifier.height(12.dp))
                AddMilestoneField(
                    value = state.newMilestoneTitle,
                    canAdd = state.canAddMilestone,
                    onValueChange = onNewMilestoneTitleChange,
                    onAdd = onAddMilestone,
                )

                Spacer(Modifier.height(28.dp))
                NotesSection(
                    notes = current.notes,
                    expanded = state.notesExpanded,
                    onToggle = onToggleNotes,
                )
            }
        }
    }

    if (showDeleteDialog) {
        ConfirmDialog(
            title = "Delete this project?",
            message = "The project and all of its milestones will be removed. " +
                "This cannot be undone.",
            confirmLabel = "Delete",
            onConfirm = {
                showDeleteDialog = false
                onDeleteDomain()
            },
            onDismiss = { showDeleteDialog = false },
        )
    }
}

@Composable
private fun NotesSection(
    notes: String,
    expanded: Boolean,
    onToggle: () -> Unit,
) {
    val chevronRotation by animateFloatAsState(
        targetValue = if (expanded) 180f else 0f,
        label = "notesChevron",
    )
    Column {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onToggle)
                .padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text("Notes & specifications", style = MaterialTheme.typography.titleMedium)
            Icon(
                imageVector = Icons.Filled.ExpandMore,
                contentDescription = if (expanded) "Collapse notes" else "Expand notes",
                modifier = Modifier.rotate(chevronRotation),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        ExpandableContent(expanded = expanded) {
            AutonomyCard(elevation = 6.dp) {
                if (notes.isBlank()) {
                    InlineEmptyState(
                        message = "Nothing written down yet. Measurements, part numbers and " +
                            "settings go here so you are not re-deriving them next month.",
                        modifier = Modifier.padding(horizontal = 20.dp),
                    )
                } else {
                    Text(
                        text = notes,
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.padding(20.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun MilestoneRow(
    milestone: Milestone,
    accent: androidx.compose.ui.graphics.Color,
    onToggle: (Boolean) -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(
            checked = milestone.isCompleted,
            onCheckedChange = onToggle,
            colors = CheckboxDefaults.colors(
                checkedColor = accent,
                checkmarkColor = MaterialTheme.colorScheme.onPrimary,
            ),
        )
        Text(
            text = milestone.title,
            style = MaterialTheme.typography.bodyLarge,
            textDecoration = if (milestone.isCompleted) TextDecoration.LineThrough else null,
            color = if (milestone.isCompleted) {
                MaterialTheme.colorScheme.onSurfaceVariant
            } else {
                MaterialTheme.colorScheme.onSurface
            },
            modifier = Modifier.weight(1f),
        )
        IconButton(onClick = onDelete) {
            Icon(
                Icons.Outlined.Delete,
                contentDescription = "Delete milestone ${milestone.title}",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun AddMilestoneField(
    value: String,
    canAdd: Boolean,
    onValueChange: (String) -> Unit,
    onAdd: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = Modifier.weight(1f),
            label = { Text("Add a milestone") },
            singleLine = true,
            shape = MaterialTheme.shapes.medium,
        )
        IconButton(onClick = onAdd, enabled = canAdd) {
            Icon(Icons.Filled.Add, contentDescription = "Add milestone")
        }
    }
}

@ScreenPreviews
@Composable
private fun DomainDetailPreview() {
    AutonomyTheme {
        DomainDetailContent(
            uiState = UiState.Success(DomainDetailState(domain = PreviewData.workshopDomain)),
            onNavigateBack = {},
            onEditDomain = {},
            onStatusChange = {},
            onMilestoneToggle = { _, _ -> },
            onMilestoneDelete = {},
            onNewMilestoneTitleChange = {},
            onAddMilestone = {},
            onToggleNotes = {},
            onDeleteDomain = {},
        )
    }
}

@ScreenPreviews
@Composable
private fun DomainDetailEmptyPreview() {
    AutonomyTheme {
        DomainDetailContent(
            uiState = UiState.Success(DomainDetailState(domain = PreviewData.emptyDomain)),
            onNavigateBack = {},
            onEditDomain = {},
            onStatusChange = {},
            onMilestoneToggle = { _, _ -> },
            onMilestoneDelete = {},
            onNewMilestoneTitleChange = {},
            onAddMilestone = {},
            onToggleNotes = {},
            onDeleteDomain = {},
        )
    }
}
