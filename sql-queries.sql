-- =========================================================
-- SkillAju: Completion & Instructor Performance Analytics
-- BigQuery SQL — Data Cleaning & Feature Engineering
-- Project: skillaju-project | Dataset: skillaju_raw
-- =========================================================


-- =========================================================
-- 1. DATA CLEANING
-- =========================================================

-- Students Cleaning --------------------------------------
CREATE OR REPLACE TABLE `skillaju-project.skillaju_raw.students_cleaned` AS
SELECT
  student_id,
  name,
  email,
  age,
  city,
  registration_date,
  acquisition_source,
  plan_type,
  (student_id IS NOT NULL AND registration_date IS NOT NULL) AS is_clean
FROM `skillaju-project.skillaju_raw.students`
WHERE student_id IS NOT NULL;


-- Instructors Cleaning ------------------------------------
CREATE OR REPLACE TABLE `skillaju-project.skillaju_raw.instructors_cleaned` AS
SELECT
  instructor_id,
  name,
  expertise,
  city,
  courses_count,
  avg_rating,
  joined_date,
  (instructor_id IS NOT NULL AND joined_date IS NOT NULL) AS is_clean
FROM `skillaju-project.skillaju_raw.instructors`
WHERE instructor_id IS NOT NULL;


-- Courses Cleaning (referential validation to instructors) ----
CREATE OR REPLACE TABLE `skillaju-project.skillaju_raw.courses_cleaned` AS
SELECT
  c.course_id,
  c.title,
  c.category,
  c.instructor_id,
  c.price_idr,
  c.duration_hours,
  c.level,
  c.avg_rating,
  c.total_enrolled,
  c.created_date,
  c.status,
  (i.instructor_id IS NOT NULL AND c.price_idr >= 0) AS is_clean
FROM `skillaju-project.skillaju_raw.courses` c
LEFT JOIN `skillaju-project.skillaju_raw.instructors_cleaned` i
  ON c.instructor_id = i.instructor_id;


-- Enrollments Cleaning (dual referential + range + date logic) ----
CREATE OR REPLACE TABLE `skillaju-project.skillaju_raw.enrollments_cleaned` AS
SELECT
  e.enrollment_id,
  e.student_id,
  e.course_id,
  e.enrolled_date,
  e.completion_date,
  e.completion_pct,
  e.certificate_issued,
  e.last_accessed,
  (
    s.student_id IS NOT NULL
    AND c.course_id IS NOT NULL
    AND e.completion_pct BETWEEN 0 AND 100
    AND (e.completion_date IS NULL OR e.completion_date >= e.enrolled_date)
  ) AS is_clean
FROM `skillaju-project.skillaju_raw.enrollments` e
LEFT JOIN `skillaju-project.skillaju_raw.students_cleaned` s
  ON e.student_id = s.student_id
LEFT JOIN `skillaju-project.skillaju_raw.courses_cleaned` c
  ON e.course_id = c.course_id;


-- Quiz Results Cleaning (referential + range) ----------------
CREATE OR REPLACE TABLE `skillaju-project.skillaju_raw.quiz_results_cleaned` AS
SELECT
  q.quiz_id,
  q.enrollment_id,
  q.student_id,
  q.course_id,
  q.quiz_number,
  q.attempt_number,
  q.score,
  q.passed,
  q.attempt_date,
  (
    e.enrollment_id IS NOT NULL
    AND q.score BETWEEN 0 AND 100
  ) AS is_clean
FROM `skillaju-project.skillaju_raw.quiz_results` q
LEFT JOIN `skillaju-project.skillaju_raw.enrollments_cleaned` e
  ON q.enrollment_id = e.enrollment_id;


-- =========================================================
-- 2. FEATURE ENGINEERING — Completion Funnel (Objective 1)
-- =========================================================

-- Base table: 1 row per enrollment with funnel flags ----------
CREATE OR REPLACE TABLE `skillaju-project.skillaju_raw.enrollment_funnel_base` AS
SELECT
  e.enrollment_id,
  e.student_id,
  e.course_id,
  s.plan_type,
  s.acquisition_source,
  c.category,
  c.level,
  c.price_idr,
  c.instructor_id,
  e.enrolled_date,
  e.completion_pct,
  e.certificate_issued,
  1 AS is_enrolled,
  CASE WHEN e.completion_pct > 0 THEN 1 ELSE 0 END AS is_started,
  CASE WHEN e.completion_pct = 100 THEN 1 ELSE 0 END AS is_completed,
  CASE WHEN e.certificate_issued = TRUE THEN 1 ELSE 0 END AS is_certified
FROM `skillaju-project.skillaju_raw.enrollments_cleaned` e
JOIN `skillaju-project.skillaju_raw.students_cleaned` s
  ON e.student_id = s.student_id
JOIN `skillaju-project.skillaju_raw.courses_cleaned` c
  ON e.course_id = c.course_id
WHERE e.is_clean = TRUE AND s.is_clean = TRUE AND c.is_clean = TRUE;


-- Funnel summary per plan_type ---------------------------------
CREATE OR REPLACE TABLE `skillaju-project.skillaju_raw.funnel_by_plan_type` AS
SELECT
  plan_type,
  SUM(is_enrolled) AS total_enrolled,
  SUM(is_started) AS total_started,
  SUM(is_completed) AS total_completed,
  SUM(is_certified) AS total_certified,
  ROUND(SUM(is_started) / SUM(is_enrolled) * 100, 1) AS enrolled_to_started_pct,
  ROUND(SUM(is_completed) / NULLIF(SUM(is_started), 0) * 100, 1) AS started_to_completed_pct,
  ROUND(SUM(is_certified) / NULLIF(SUM(is_completed), 0) * 100, 1) AS completed_to_certified_pct,
  ROUND(SUM(is_certified) / SUM(is_enrolled) * 100, 1) AS overall_conversion_pct
FROM `skillaju-project.skillaju_raw.enrollment_funnel_base`
GROUP BY plan_type
ORDER BY total_enrolled DESC;


-- Funnel summary per acquisition_source ---------------------------
CREATE OR REPLACE TABLE `skillaju-project.skillaju_raw.funnel_by_acquisition` AS
SELECT
  acquisition_source,
  SUM(is_enrolled) AS total_enrolled,
  SUM(is_started) AS total_started,
  SUM(is_completed) AS total_completed,
  ROUND(SUM(is_started) / SUM(is_enrolled) * 100, 1) AS enrolled_to_started_pct,
  ROUND(SUM(is_completed) / NULLIF(SUM(is_started), 0) * 100, 1) AS started_to_completed_pct,
  ROUND(SUM(is_completed) / SUM(is_enrolled) * 100, 1) AS overall_conversion_pct
FROM `skillaju-project.skillaju_raw.enrollment_funnel_base`
GROUP BY acquisition_source
ORDER BY total_enrolled DESC;


-- =========================================================
-- 3. FEATURE ENGINEERING — Course & Instructor Performance (Objective 2)
-- =========================================================

-- Per-course performance (completion + quiz pass rate via CTE) ----
CREATE OR REPLACE TABLE `skillaju-project.skillaju_raw.course_performance_summary` AS
WITH funnel_agg AS (
  SELECT
    course_id,
    SUM(is_enrolled) AS total_enrolled,
    SUM(is_started) AS total_started,
    SUM(is_completed) AS total_completed,
    ROUND(SUM(is_completed) / NULLIF(SUM(is_started), 0) * 100, 1) AS completion_rate_pct
  FROM `skillaju-project.skillaju_raw.enrollment_funnel_base`
  GROUP BY course_id
),
quiz_agg AS (
  SELECT
    course_id,
    COUNT(*) AS total_quiz_attempts,
    ROUND(AVG(score), 1) AS avg_score,
    ROUND(SUM(CASE WHEN passed THEN 1 ELSE 0 END) / COUNT(*) * 100, 1) AS pass_rate_pct
  FROM `skillaju-project.skillaju_raw.quiz_results_cleaned`
  GROUP BY course_id
)
SELECT
  c.course_id,
  c.title,
  c.category,
  c.level,
  c.price_idr,
  c.avg_rating,
  c.instructor_id,
  c.status,
  f.total_enrolled,
  f.completion_rate_pct,
  q.avg_score,
  q.pass_rate_pct
FROM `skillaju-project.skillaju_raw.courses_cleaned` c
LEFT JOIN funnel_agg f ON c.course_id = f.course_id
LEFT JOIN quiz_agg q ON c.course_id = q.course_id
ORDER BY f.completion_rate_pct ASC;


-- Category x Level performance (raw breakdown) ---------------------
CREATE OR REPLACE TABLE `skillaju-project.skillaju_raw.category_level_performance` AS
SELECT
  category,
  level,
  COUNT(DISTINCT course_id) AS num_courses,
  SUM(total_enrolled) AS total_enrolled,
  ROUND(AVG(completion_rate_pct), 1) AS avg_completion_rate_pct,
  ROUND(AVG(pass_rate_pct), 1) AS avg_pass_rate_pct,
  ROUND(AVG(avg_rating), 2) AS avg_course_rating,
  ROUND(AVG(price_idr), 0) AS avg_price_idr
FROM `skillaju-project.skillaju_raw.course_performance_summary`
WHERE status = 'published'
GROUP BY category, level
ORDER BY avg_completion_rate_pct ASC;


-- Category performance (enrollment-weighted, dashboard-ready) --------
CREATE OR REPLACE TABLE `skillaju-project.skillaju_raw.category_performance_summary` AS
SELECT
  category,
  SUM(num_courses) AS num_courses,
  SUM(total_enrolled) AS total_enrolled,
  ROUND(SUM(avg_completion_rate_pct * total_enrolled) / SUM(total_enrolled), 1) AS weighted_completion_pct,
  ROUND(SUM(avg_pass_rate_pct * total_enrolled) / SUM(total_enrolled), 1) AS weighted_pass_rate_pct
FROM `skillaju-project.skillaju_raw.category_level_performance`
GROUP BY category;


-- Level performance (enrollment-weighted, dashboard-ready) ----------
CREATE OR REPLACE TABLE `skillaju-project.skillaju_raw.level_performance_summary` AS
SELECT
  level,
  SUM(num_courses) AS num_courses,
  SUM(total_enrolled) AS total_enrolled,
  ROUND(SUM(avg_completion_rate_pct * total_enrolled) / SUM(total_enrolled), 1) AS weighted_completion_pct,
  ROUND(SUM(avg_pass_rate_pct * total_enrolled) / SUM(total_enrolled), 1) AS weighted_pass_rate_pct
FROM `skillaju-project.skillaju_raw.category_level_performance`
GROUP BY level;


-- Instructor performance (enrollment-weighted) -----------------------
CREATE OR REPLACE TABLE `skillaju-project.skillaju_raw.instructor_performance_summary` AS
SELECT
  i.instructor_id,
  i.name,
  i.expertise,
  i.avg_rating AS instructor_avg_rating,
  COUNT(cp.course_id) AS num_published_courses,
  SUM(cp.total_enrolled) AS total_enrolled,
  ROUND(SUM(cp.completion_rate_pct * cp.total_enrolled) / NULLIF(SUM(cp.total_enrolled), 0), 1) AS weighted_completion_pct,
  ROUND(SUM(cp.pass_rate_pct * cp.total_enrolled) / NULLIF(SUM(cp.total_enrolled), 0), 1) AS weighted_pass_rate_pct
FROM `skillaju-project.skillaju_raw.instructors_cleaned` i
LEFT JOIN `skillaju-project.skillaju_raw.course_performance_summary` cp
  ON i.instructor_id = cp.instructor_id AND cp.status = 'published'
GROUP BY i.instructor_id, i.name, i.expertise, i.avg_rating
HAVING num_published_courses > 0
ORDER BY weighted_completion_pct ASC;


-- =========================================================
-- 4. DASHBOARD SUPPORT TABLE
-- =========================================================

-- KPI Summary (1 row, for scorecards) --------------------------------
CREATE OR REPLACE TABLE `skillaju-project.skillaju_raw.kpi_summary` AS
SELECT
  (SELECT COUNT(*) FROM `skillaju-project.skillaju_raw.students_cleaned`) AS total_students,
  (SELECT COUNT(*) FROM `skillaju-project.skillaju_raw.courses_cleaned` WHERE status = 'published') AS total_published_courses,
  (SELECT COUNT(*) FROM `skillaju-project.skillaju_raw.enrollments_cleaned`) AS total_enrollments,
  (SELECT ROUND(SUM(is_completed) / SUM(is_started) * 100, 1) FROM `skillaju-project.skillaju_raw.enrollment_funnel_base`) AS overall_completion_rate_pct,
  (SELECT ROUND(AVG(score), 1) FROM `skillaju-project.skillaju_raw.quiz_results_cleaned`) AS overall_avg_quiz_score,
  (SELECT COUNT(*) FROM `skillaju-project.skillaju_raw.enrollments_cleaned` WHERE certificate_issued = TRUE) AS total_certificates_issued;


-- =========================================================
-- 5. ANCILLARY EXPLORATORY QUERIES (not materialized as tables)
-- =========================================================

-- Category performance, unweighted level order check ------------------
-- SELECT level, SUM(num_courses) AS num_courses, SUM(total_enrolled) AS total_enrolled,
--   ROUND(SUM(avg_completion_rate_pct * total_enrolled) / SUM(total_enrolled), 1) AS weighted_avg_completion_pct,
--   ROUND(SUM(avg_pass_rate_pct * total_enrolled) / SUM(total_enrolled), 1) AS weighted_avg_pass_rate_pct
-- FROM `skillaju-project.skillaju_raw.category_level_performance`
-- GROUP BY level
-- ORDER BY weighted_avg_completion_pct ASC;
