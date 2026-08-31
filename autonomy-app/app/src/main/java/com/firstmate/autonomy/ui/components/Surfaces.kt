package com.firstmate.autonomy.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.firstmate.autonomy.ui.preview.ThemePreviews
import com.firstmate.autonomy.ui.theme.AutonomyShape
import com.firstmate.autonomy.ui.theme.AutonomyTheme

/**
 * The app's elevated card: 20dp corners, a soft drop shadow, and a hairline
 * outline.
 *
 * The outline is not decoration. On the obsidian ground, surface (#1E293B) and
 * background (#0F172A) differ by only 1.22:1, which is a deliberate,
 * low-glare look but too subtle to delimit a card on a dim screen or for a
 * low-vision reader. The 3:1 outline gives the boundary a second, non-luminance
 * cue without brightening the surface.
 */
@Composable
fun AutonomyCard(
    modifier: Modifier = Modifier,
    elevation: Dp = 10.dp,
    outlined: Boolean = true,
    containerColor: androidx.compose.ui.graphics.Color = MaterialTheme.colorScheme.surfaceContainerHigh,
    content: @Composable ColumnScope.() -> Unit,
) {
    Card(
        modifier = modifier
            .fillMaxWidth()
            .shadow(
                elevation = elevation,
                shape = AutonomyShape.card,
                // A tinted, mostly-transparent shadow: a pure black drop shadow
                // is invisible on obsidian, so the lift comes from a coloured
                // ambient instead.
                ambientColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.5f),
                spotColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.5f),
            ),
        shape = AutonomyShape.card,
        colors = CardDefaults.cardColors(containerColor = containerColor),
        border = if (outlined) {
            BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
        } else {
            null
        },
        content = content,
    )
}

/**
 * Expand/collapse with a spring height animation and a cross-faded body.
 *
 * `expandVertically` alone snaps the content's alpha, which reads as a jump on
 * a tall body; pairing it with a fade is what makes the reveal feel continuous.
 */
@Composable
fun ExpandableContent(
    expanded: Boolean,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    AnimatedVisibility(
        visible = expanded,
        modifier = modifier,
        enter = expandVertically(
            animationSpec = spring(
                dampingRatio = Spring.DampingRatioNoBouncy,
                stiffness = Spring.StiffnessMediumLow,
            ),
        ) + fadeIn(animationSpec = spring(stiffness = Spring.StiffnessMediumLow)),
        exit = shrinkVertically(
            animationSpec = spring(
                dampingRatio = Spring.DampingRatioNoBouncy,
                stiffness = Spring.StiffnessMedium,
            ),
        ) + fadeOut(),
        content = { content() },
    )
}

@ThemePreviews
@Composable
private fun AutonomyCardPreview() {
    AutonomyTheme {
        Column(
            Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            AutonomyCard {
                Column(Modifier.padding(20.dp)) {
                    Text("Elevated card", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "20dp corners, tinted shadow, hairline outline.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}
