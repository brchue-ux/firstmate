package com.firstmate.autonomy.data.local.migration

import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

/**
 * Version 1 kept projects and habits in separate tables. Version 2 merges them
 * into one `goals` table, moves check-ins down onto a new `particulars` level,
 * and adds `moments`.
 *
 * The DDL below is written to match exactly what Room generates for the v2
 * entities - table and index names, column order, affinities, and the foreign
 * key clauses - because Room verifies the schema when it opens the file and
 * refuses a database that does not match.
 *
 * What each old row becomes:
 *  - a project  -> a goal, keeping its id, with its milestones as particulars
 *  - a milestone that was already ticked off -> also a moment, so finishing it
 *    is not silently thrown away
 *  - a habit -> a goal with a single particular named "Daily", which is where
 *    its check-in history lands
 *
 * Habit ids are shifted past the highest project id so the two id spaces cannot
 * collide when they merge into one table.
 */
val MIGRATION_1_2 = object : Migration(1, 2) {
    override fun migrate(db: SupportSQLiteDatabase) {
        val now = System.currentTimeMillis()

        db.execSQL(
            "CREATE TABLE IF NOT EXISTS `goals` (" +
                "`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, " +
                "`title` TEXT NOT NULL, `category` TEXT NOT NULL, `status` TEXT NOT NULL, " +
                "`notes` TEXT NOT NULL, `position` INTEGER NOT NULL, " +
                "`created_at` INTEGER NOT NULL, `updated_at` INTEGER NOT NULL)",
        )
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS `particulars` (" +
                "`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, " +
                "`goal_id` INTEGER NOT NULL, `title` TEXT NOT NULL, `kind` TEXT NOT NULL, " +
                "`notes` TEXT NOT NULL, `position` INTEGER NOT NULL, " +
                "`created_at` INTEGER NOT NULL, " +
                "FOREIGN KEY(`goal_id`) REFERENCES `goals`(`id`) " +
                "ON UPDATE NO ACTION ON DELETE CASCADE )",
        )
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS `index_particulars_goal_id` " +
                "ON `particulars` (`goal_id`)",
        )
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS `check_ins` (" +
                "`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, " +
                "`particular_id` INTEGER NOT NULL, `date_epoch_day` INTEGER NOT NULL, " +
                "FOREIGN KEY(`particular_id`) REFERENCES `particulars`(`id`) " +
                "ON UPDATE NO ACTION ON DELETE CASCADE )",
        )
        db.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS " +
                "`index_check_ins_particular_id_date_epoch_day` " +
                "ON `check_ins` (`particular_id`, `date_epoch_day`)",
        )
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS `index_check_ins_date_epoch_day` " +
                "ON `check_ins` (`date_epoch_day`)",
        )
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS `moments` (" +
                "`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, " +
                "`particular_id` INTEGER NOT NULL, `label` TEXT NOT NULL, " +
                "`date_epoch_day` INTEGER NOT NULL, `note` TEXT NOT NULL, " +
                "`created_at` INTEGER NOT NULL, " +
                "FOREIGN KEY(`particular_id`) REFERENCES `particulars`(`id`) " +
                "ON UPDATE NO ACTION ON DELETE CASCADE )",
        )
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS `index_moments_particular_id` " +
                "ON `moments` (`particular_id`)",
        )
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS `index_moments_date_epoch_day` " +
                "ON `moments` (`date_epoch_day`)",
        )

        // Projects keep their ids, so anything already pointing at one still lines up.
        db.execSQL(
            "INSERT INTO `goals` " +
                "(`id`, `title`, `category`, `status`, `notes`, `position`, " +
                "`created_at`, `updated_at`) " +
                "SELECT `id`, `title`, `category`, " +
                "CASE `status` WHEN 'COMPLETED' THEN 'DONE' " +
                "WHEN 'ON_HOLD' THEN 'PAUSED' ELSE 'ACTIVE' END, " +
                "`notes`, `id`, `created_at`, `updated_at` FROM `domains`",
        )
        db.execSQL(
            "INSERT INTO `particulars` " +
                "(`goal_id`, `title`, `kind`, `notes`, `position`, `created_at`) " +
                "SELECT `domain_id`, `title`, 'ROCK', '', `position`, $now FROM `milestones`",
        )
        // A milestone that was already done is a thing that happened - keep it.
        db.execSQL(
            "INSERT INTO `moments` " +
                "(`particular_id`, `label`, `date_epoch_day`, `note`, `created_at`) " +
                "SELECT p.`id`, 'Completed', ${now / 86_400_000L}, '', $now " +
                "FROM `milestones` m " +
                "JOIN `particulars` p ON p.`goal_id` = m.`domain_id` AND p.`title` = m.`title` " +
                "WHERE m.`is_completed` = 1",
        )

        // Habits become goals, shifted clear of the project id space.
        db.execSQL(
            "INSERT INTO `goals` " +
                "(`id`, `title`, `category`, `status`, `notes`, `position`, " +
                "`created_at`, `updated_at`) " +
                "SELECT h.`id` + (SELECT IFNULL(MAX(`id`), 0) FROM `domains`), " +
                "h.`name`, 'Habit', " +
                "CASE h.`is_archived` WHEN 1 THEN 'PAUSED' ELSE 'ACTIVE' END, " +
                "h.`description`, " +
                "h.`position` + (SELECT IFNULL(MAX(`id`), 0) FROM `domains`), " +
                "$now, $now FROM `habits` h",
        )
        db.execSQL(
            "INSERT INTO `particulars` " +
                "(`goal_id`, `title`, `kind`, `notes`, `position`, `created_at`) " +
                "SELECT h.`id` + (SELECT IFNULL(MAX(`id`), 0) FROM `domains`), " +
                "'Daily', 'ROCK', '', 0, $now FROM `habits` h",
        )
        db.execSQL(
            "INSERT INTO `check_ins` (`particular_id`, `date_epoch_day`) " +
                "SELECT p.`id`, c.`date_epoch_day` FROM `habit_check_ins` c " +
                "JOIN `particulars` p ON p.`goal_id` = " +
                "c.`habit_id` + (SELECT IFNULL(MAX(`id`), 0) FROM `domains`) " +
                "AND p.`title` = 'Daily'",
        )

        // A decision can now name the goal it was about. No foreign key: SQLite
        // cannot add one to an existing table without a full rebuild, and a
        // deleted goal is cleared by the repository instead.
        db.execSQL("ALTER TABLE `decisions` ADD COLUMN `goal_id` INTEGER")
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS `index_decisions_goal_id` " +
                "ON `decisions` (`goal_id`)",
        )

        db.execSQL("DROP TABLE IF EXISTS `habit_check_ins`")
        db.execSQL("DROP TABLE IF EXISTS `habits`")
        db.execSQL("DROP TABLE IF EXISTS `milestones`")
        db.execSQL("DROP TABLE IF EXISTS `domains`")
    }
}
