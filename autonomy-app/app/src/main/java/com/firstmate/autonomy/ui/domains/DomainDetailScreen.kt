package com.firstmate.autonomy.ui.domains

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.firstmate.autonomy.di.AutonomyViewModelFactory
import com.firstmate.autonomy.domain.model.DomainStatus
import com.firstmate.autonomy.domain.model.Milestone
import com.firstmate.autonomy.ui.components.ChoiceChipRow
import com.firstmate.autonomy.ui.components.ConfirmDialog
import com.firstmate.autonomy.ui.components.InlineEmptyState
import com.firstmate.autonomy.ui.components.LabelChip
import com.firstmate.autonomy.ui.components.LabeledProgress
import com.firstmate.autonomy.ui.components.SectionHeader
import com.firstmate.autonomy.ui.preview.PreviewData
import com.firstmate.autonomy.ui.preview.ScreenPreviews
import com.firstmate.autonomy.ui.theme.AutonomyTheme

/** One project: milestones, notes and stage. */
@Composable
fun DomainDetailScreen(
    onNavigateBack: () -> Unit,
    onEditDomain: (Long) -> Unit,
    modifier: Modifier = Modifier,
    viewModel: DomainDetailViewModel = viewModel(factory = AutonomyViewModelFactory.Factory),
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()

    // Deleting the project, or losing it to a delete elsewhere, closes the screen.
    LaunchedEffect(uiState.isDeleted, uiState.isLoading, uiState.domain) {
        if (uiState.isDeleted || (!uiState.isLoading && uiState.domain == null)) {
            onNavigateBack()
        }
    }

    DomainDetailContent(
        uiState = uiState,
        onNavigateBack = onNavigateBack,
        onEditDomain = onEditDomain,
        onStatusChange = viewModel::setStatus,
        onMilestoneToggle = viewModel::setMilestoneCompleted,
        onMilestoneDelete = viewModel::deleteMilestone,
        onNewMilestoneTitleChange = viewModel::onNewMilestoneTitleChange,
        onAddMilestone = viewModel::addMilestone,
        onDeleteDomain = viewModel::deleteDomain,
        modifier = modifier,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DomainDetailContent(
    uiState: DomainDetailUiState,
    onNavigateBack: () -> Unit,
    onEditDomain: (Long) -> Unit,
    onStatusChange: (DomainStatus) -> Unit,
    onMilestoneToggle: (Milestone, Boolean) -> Unit,
    onMilestoneDelete: (Milestone) -> Unit,
    onNewMilestoneTitleChange: (String) -> Unit,
    onAddMilestone: () -> Unit,
    onDeleteDomain: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val domain = uiState.domain
    var showDeleteDialog by remember { mutableStateOf(false) }

    Scaffold(
        modifier = modifier,
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        topBar = {
            TopAppBar(
                title = { Text(domain?.title.orEmpty(), maxLines = 1) },
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
            )
        },
    ) { innerPadding ->
        if (domain == null) return@Scaffold

        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 24.dp),
        ) {
            LabelChip(domain.category)
            Spacer(Modifier.height(16.dp))

            LabeledProgress(
                label = "Progress",
                progress = domain.progress,
                trailingText = "${domain.completedMilestoneCount} of ${domain.milestoneCount}" +
                    " · ${domain.progressPercent}%",
                accessibilityText = "Progress, ${domain.completedMilestoneCount} of " +
                    "${domain.milestoneCount} milestones, ${domain.progressPercent} percent",
            )
            Spacer(Modifier.height(20.dp))

            ChoiceChipRow(
                label = "Status",
                options = DomainStatus.entries,
                selected = domain.status,
                onSelect = onStatusChange,
                optionLabel = { it.label },
            )
            Spacer(Modifier.height(24.dp))

            SectionHeader(title = "Milestones")
            if (domain.milestones.isEmpty()) {
                InlineEmptyState(
                    "No milestones yet. Break the project into steps small enough to tick off " +
                        "in one sitting.",
                )
            } else {
                domain.milestones.forEach { milestone ->
                    MilestoneRow(
                        milestone = milestone,
                        onToggle = { checked -> onMilestoneToggle(milestone, checked) },
                        onDelete = { onMilestoneDelete(milestone) },
                    )
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                }
            }
            Spacer(Modifier.height(12.dp))

            AddMilestoneField(
                value = uiState.newMilestoneTitle,
                canAdd = uiState.canAddMilestone,
                onValueChange = onNewMilestoneTitleChange,
                onAdd = onAddMilestone,
            )
            Spacer(Modifier.height(28.dp))

            SectionHeader(title = "Notes & specifications")
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
                ),
            ) {
                if (domain.notes.isBlank()) {
                    InlineEmptyState(
                        message = "Nothing written down yet. Measurements, part numbers and " +
                            "settings go here so you are not re-deriving them next month.",
                        modifier = Modifier.padding(horizontal = 16.dp),
                    )
                } else {
                    Text(
                        text = domain.notes,
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.padding(16.dp),
                    )
                }
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
private fun MilestoneRow(
    milestone: Milestone,
    onToggle: (Boolean) -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(checked = milestone.isCompleted, onCheckedChange = onToggle)
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
            uiState = DomainDetailUiState(isLoading = false, domain = PreviewData.workshopDomain),
            onNavigateBack = {},
            onEditDomain = {},
            onStatusChange = {},
            onMilestoneToggle = { _, _ -> },
            onMilestoneDelete = {},
            onNewMilestoneTitleChange = {},
            onAddMilestone = {},
            onDeleteDomain = {},
        )
    }
}

@ScreenPreviews
@Composable
private fun DomainDetailEmptyPreview() {
    AutonomyTheme {
        DomainDetailContent(
            uiState = DomainDetailUiState(isLoading = false, domain = PreviewData.emptyDomain),
            onNavigateBack = {},
            onEditDomain = {},
            onStatusChange = {},
            onMilestoneToggle = { _, _ -> },
            onMilestoneDelete = {},
            onNewMilestoneTitleChange = {},
            onAddMilestone = {},
            onDeleteDomain = {},
        )
    }
}
