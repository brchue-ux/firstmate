package com.firstmate.autonomy.ui.navigation

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Balance
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.TaskAlt
import androidx.compose.material.icons.outlined.Balance
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material.icons.outlined.TaskAlt
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * Every route in the app.
 *
 * Editor routes take an optional id: absent (or [NO_ID]) means "create new",
 * present means "edit that row". One route per editor keeps the ViewModel and
 * the back stack simple.
 */
object Routes {
    const val TODAY = "today"
    const val GOAL_LIST = "goals"
    const val SPACE = "space"
    const val DECISION_LIST = "log"
    const val YOU = "you"

    const val GOAL_EDITOR = "goal-editor?$ARG_GOAL_ID={$ARG_GOAL_ID}"
    const val DECISION_EDITOR = "decision-editor?$ARG_DECISION_ID={$ARG_DECISION_ID}"

    fun goalEditor(goalId: Long? = null): String =
        "goal-editor?$ARG_GOAL_ID=${goalId ?: NO_ID}"

    fun decisionEditor(decisionId: Long? = null): String =
        "decision-editor?$ARG_DECISION_ID=${decisionId ?: NO_ID}"
}

const val ARG_GOAL_ID = "goalId"
const val ARG_DECISION_ID = "decisionId"

/** Sentinel for "no row selected", i.e. the editor is in create mode. */
const val NO_ID = -1L

/**
 * The five tabs, in display order.
 *
 * Space sits in the middle and is marked [isPrimary]: it is where you spend
 * your time, and the centre of a five-slot bar is the easiest reach on a
 * phone held one-handed.
 */
enum class TopLevelDestination(
    val route: String,
    val label: String,
    val selectedIcon: ImageVector,
    val unselectedIcon: ImageVector,
    val isPrimary: Boolean = false,
) {
    TODAY(
        route = Routes.TODAY,
        label = "Today",
        selectedIcon = Icons.Filled.TaskAlt,
        unselectedIcon = Icons.Outlined.TaskAlt,
    ),
    GOALS(
        route = Routes.GOAL_LIST,
        label = "Goals",
        selectedIcon = Icons.Filled.Star,
        unselectedIcon = Icons.Outlined.Star,
    ),
    SPACE(
        route = Routes.SPACE,
        label = "Space",
        selectedIcon = Icons.Filled.AutoAwesome,
        unselectedIcon = Icons.Outlined.AutoAwesome,
        isPrimary = true,
    ),
    LOG(
        route = Routes.DECISION_LIST,
        label = "Log",
        selectedIcon = Icons.Filled.Balance,
        unselectedIcon = Icons.Outlined.Balance,
    ),
    YOU(
        route = Routes.YOU,
        label = "You",
        selectedIcon = Icons.Filled.Person,
        unselectedIcon = Icons.Outlined.Person,
    ),
}
