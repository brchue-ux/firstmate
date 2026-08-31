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
import androidx.compose.material3.AssistChip
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.horizontalScroll
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.firstmate.autonomy.domain.model.DomainCategories
import com.firstmate.autonomy.domain.model.DomainStatus
import com.firstmate.autonomy.ui.components.AutonomyMultilineField
import com.firstmate.autonomy.ui.components.AutonomyTextField
import com.firstmate.autonomy.ui.components.ChoiceChipRow
import com.firstmate.autonomy.ui.components.PrimaryActionButton
import com.firstmate.autonomy.ui.preview.ScreenPreviews
import com.firstmate.autonomy.ui.theme.AutonomyTheme

/** Create or edit a project. Same form either way. */
@Composable
fun DomainEditorScreen(
    onNavigateBack: () -> Unit,
    modifier: Modifier = Modifier,
    viewModel: DomainEditorViewModel = hiltViewModel(),
) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()

    LaunchedEffect(uiState.isSaved) {
        if (uiState.isSaved) onNavigateBack()
    }

    DomainEditorContent(
        uiState = uiState,
        onTitleChange = viewModel::onTitleChange,
        onCategoryChange = viewModel::onCategoryChange,
        onStatusChange = viewModel::onStatusChange,
        onNotesChange = viewModel::onNotesChange,
        onSave = viewModel::save,
        onNavigateBack = onNavigateBack,
        modifier = modifier,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DomainEditorContent(
    uiState: DomainEditorUiState,
    onTitleChange: (String) -> Unit,
    onCategoryChange: (String) -> Unit,
    onStatusChange: (DomainStatus) -> Unit,
    onNotesChange: (String) -> Unit,
    onSave: () -> Unit,
    onNavigateBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Scaffold(
        modifier = modifier,
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        topBar = {
            TopAppBar(
                title = { Text(uiState.screenTitle) },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            AutonomyTextField(
                label = "Title",
                value = uiState.title,
                onValueChange = onTitleChange,
                placeholder = "What are you building or practising?",
                isError = uiState.showValidationErrors && uiState.titleError != null,
                supportingText = uiState.titleError.takeIf { uiState.showValidationErrors },
            )

            Column {
                AutonomyTextField(
                    label = "Category",
                    value = uiState.category,
                    onValueChange = onCategoryChange,
                    placeholder = "Workshop, Technical Setup, Skill Practice…",
                    isError = uiState.showValidationErrors && uiState.categoryError != null,
                    supportingText = uiState.categoryError.takeIf { uiState.showValidationErrors },
                )
                Spacer(Modifier.height(8.dp))
                // Suggestions only - the field itself takes any text.
                Row(
                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    DomainCategories.suggestions.forEach { suggestion ->
                        AssistChip(
                            onClick = { onCategoryChange(suggestion) },
                            label = { Text(suggestion) },
                        )
                    }
                }
            }

            ChoiceChipRow(
                label = "Status",
                options = DomainStatus.entries,
                selected = uiState.status,
                onSelect = onStatusChange,
                optionLabel = { it.label },
            )

            AutonomyMultilineField(
                label = "Notes & specifications",
                value = uiState.notes,
                onValueChange = onNotesChange,
                placeholder = "Measurements, part numbers, settings, decisions already made…",
                minLines = 5,
            )

            PrimaryActionButton(
                text = if (uiState.isEditing) "Save changes" else "Create project",
                onClick = onSave,
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                text = "Milestones are added on the project itself, once it exists.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@ScreenPreviews
@Composable
private fun DomainEditorPreview() {
    AutonomyTheme {
        DomainEditorContent(
            uiState = DomainEditorUiState(
                title = "Bench power supply rebuild",
                category = "Workshop",
                status = DomainStatus.IN_PROGRESS,
                notes = "Linear supply, 0-30V / 0-5A.",
                isEditing = true,
            ),
            onTitleChange = {},
            onCategoryChange = {},
            onStatusChange = {},
            onNotesChange = {},
            onSave = {},
            onNavigateBack = {},
        )
    }
}

@ScreenPreviews
@Composable
private fun DomainEditorBlankPreview() {
    AutonomyTheme {
        DomainEditorContent(
            uiState = DomainEditorUiState(showValidationErrors = true),
            onTitleChange = {},
            onCategoryChange = {},
            onStatusChange = {},
            onNotesChange = {},
            onSave = {},
            onNavigateBack = {},
        )
    }
}
