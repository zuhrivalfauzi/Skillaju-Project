# SkillAju: Completion & Instructor Performance Analytics

> **End-to-end analytics project** using BigQuery SQL, Python (Google Colab), and Looker Studio to identify why students disengage mid-course and which instructors/categories drive that pattern.

---

## Table of Contents

1. [Business Understanding](#1-business-understanding)
2. [Data Source](#2-data-source)
3. [Cloud Environment & Tech Stack](#3-cloud-environment--tech-stack)
4. [Data Cleaning](#4-data-cleaning)
5. [Data Extraction & Feature Engineering](#5-data-extraction--feature-engineering)
6. [Key Findings](#6-key-findings)
7. [Dashboard](#7-dashboard)
8. [Insights & Strategic Recommendations](#8-insights--strategic-recommendations)
9. [Limitations & Methodology Notes](#limitations--methodology-notes)

---

## 1. Business Understanding

### 1.1 Business Background

SkillAju is a fictional online course marketplace offering digital-skill courses (SQL, Python, Excel, Power BI, Statistics, Data Engineering). The platform runs a freemium model — students hold one of three plan types: **free**, **basic**, or **pro**. Each course is created by an instructor and carries its own price, difficulty level, and rating. The platform tracks each student's learning journey from enrollment (`enrollments`) through quiz attempts (`quiz_results`) to certificate issuance (upon 100% completion).

### 1.2 Business Problem

Initial data exploration revealed two related problems:

- **Problem 1 — Completion/Engagement Leak**: Of ~10,380 enrollments, the majority never finish their course (average completion 54%, but only ~31% actually reach 100%; certificates are issued for just 30.7% of enrollments). Students "start" easily but "parking" mid-course is widespread.
- **Problem 2 — Course & Instructor Performance Gap**: Not all courses/instructors contribute equally. There is a possibility that specific categories, levels, or instructors systematically underperform in completion or quiz pass rate — a potential root cause behind Problem 1.

### 1.3 Project Objectives

| # | Objective | Analysis Focus |
|---|---|---|
| 1 | Identify at which stage students "leak" out of the learning funnel (enroll → progress → complete → certificate) | Completion Funnel |
| 2 | Identify underperforming courses & instructors (low completion/pass rate) contributing to the funnel leak | Course & Instructor Performance |

### 1.4 Key Business Questions (KBQ)

**Objective 1 — Completion Funnel:**
- At which stage (enrolled → started → in progress → completed → certified) do students drop off the most?
- Does the drop-off pattern differ across `plan_type` (free vs. basic vs. pro)? Across `acquisition_source`?
- How large is the "lost potential" — e.g., how many paying (basic/pro) students never complete a course?

**Objective 2 — Course & Instructor Performance:**
- Which course category or difficulty level has the lowest completion & quiz pass rate?
- Which instructors consistently underperform (low completion despite high ratings, or vice versa)?
- Is there a relationship between course price (`price_idr`) and completion rate?

---

## 2. Data Source

**Dataset:** SkillAju: Marketplace Kelas Online (Ngulik Data)
**Format:** 5 CSV tables, ~44,335 total rows, 2.6 MB

| Source Table | Description | Rows |
|---|---|---|
| `students` | Student demographics, plan type, acquisition source | 3,000 |
| `instructors` | Instructor profile, expertise, rating | 30 |
| `courses` | Course catalog: category, price, level, rating, status | 50 |
| `enrollments` | Student ↔ course enrollment, completion progress, certificate | 10,380 |
| `quiz_results` | Quiz attempts per enrollment, score, pass/fail | 30,875 |

**Reference Date Range:** `registration_date` 2022-01-01 – 2025-02-28; `enrolled_date` 2022-01-14 – 2025-03-15

---

## 3. Cloud Environment & Tech Stack

**Tools:** BigQuery SQL (Sandbox, free tier) · Python (Pandas, Matplotlib) · Google Colab · Looker Studio
**Connection:** All layers connect directly to BigQuery — no data is exported to local files between stages.

---

## 4. Data Cleaning

All cleaning was performed in BigQuery, producing `_cleaned` tables with an audit column `is_clean` used consistently across all downstream queries.

### 4.1 Cleaning Strategy per Table

**`students_cleaned`**
- Filter `student_id IS NOT NULL`
- `is_clean` = TRUE if `student_id` and `registration_date` are both present
- Result: 3,000 / 3,000 rows clean

**`instructors_cleaned`**
- Filter `instructor_id IS NOT NULL`
- `is_clean` = TRUE if `instructor_id` and `joined_date` are both present
- Result: 30 / 30 rows clean

**`courses_cleaned`**
- Referential validation: `LEFT JOIN` to `instructors_cleaned` — every course's `instructor_id` must exist in the instructor master table
- Filter `price_idr >= 0`
- Result: 50 / 50 rows clean

**`enrollments_cleaned`**
- Dual referential validation: `LEFT JOIN` to `students_cleaned` and `courses_cleaned`
- Range validation: `completion_pct BETWEEN 0 AND 100`
- Date sequence validation: `completion_date IS NULL OR completion_date >= enrolled_date`
- Result: 10,380 / 10,380 rows clean

**`quiz_results_cleaned`**
- Referential validation: `LEFT JOIN` to `enrollments_cleaned`
- Range validation: `score BETWEEN 0 AND 100`
- Result: 30,875 / 30,875 rows clean

### 4.2 Audit Column `is_clean`

Every cleaned table includes a boolean `is_clean` column used as a consistent filter across all downstream queries. This dataset turned out to be fully clean (0 rejected rows across all 5 tables) — the `is_clean` methodology is retained for reproducibility and as best practice for real-world/messier datasets.

---

## 5. Data Extraction & Feature Engineering

### 5.1 Completion Funnel

Built from `enrollment_funnel_base`, joining `enrollments_cleaned` with `students_cleaned` (plan_type, acquisition_source) and `courses_cleaned` (category, level, price).

**Funnel Steps:**
```
Enrolled (all enrollments)
    → Started      (completion_pct > 0)
    → Completed    (completion_pct = 100)
    → Certified    (certificate_issued = TRUE)
```

**Note:** `completed_to_certified_pct = 100%` across every segment — certificates are issued automatically upon 100% completion. This means "Certified" carries no additional signal beyond "Completed"; the analysis therefore focuses on the Enrolled → Started → Completed transition.

### 5.2 Course & Instructor Performance Aggregation

| Table | Contents | Used For |
|---|---|---|
| `funnel_by_plan_type` | Funnel counts & conversion % per plan_type | Objective 1 |
| `funnel_by_acquisition` | Funnel counts & conversion % per acquisition_source | Objective 1 |
| `course_performance_summary` | Completion rate, quiz pass rate, avg score per course (CTE-joined) | Objective 2 |
| `category_level_performance` | Aggregated completion/pass rate per category × level | Objective 2 |
| `category_performance_summary` | Enrollment-weighted completion/pass rate per category | Objective 2 (dashboard) |
| `instructor_performance_summary` | Enrollment-weighted completion/pass rate per instructor | Objective 2 |
| `kpi_summary` | Platform-wide headline metrics (1 row) | Dashboard KPI row |

**Methodology note — weighted averages:** Category and instructor-level averages are weighted by `total_enrolled` (`SUM(rate * enrolled) / SUM(enrolled)`), not simple averages, so that categories/instructors with more students carry proportional influence in the ranking — avoiding distortion from small-sample courses.

---

## 6. Key Findings

EDA conducted in Google Colab with direct BigQuery connection. Notebook: [Python for EDA →](https://colab.research.google.com/drive/1-Kmnu-q62FRIixRHjjHAkr423W4D2rVO?usp=sharing)

---

### Finding 1 — The Bottleneck Is Learning, Not Signing Up

<img width="885" height="484" alt="image" src="https://github.com/user-attachments/assets/70419985-1bdd-448d-891d-db40a527101b" />

Across ~10,380 enrollments, 97% of students successfully start a course (`completion_pct > 0`), but only **~31% ever reach 100% completion**. This pattern is **nearly identical** across all three plan types (free 30.9%, basic 30.3%, pro 30.2%) and across every acquisition channel (28.6%–31.6%).

**The insight:** This rules out "lack of motivation from free users" (paying users behave identically) and "wrong marketing channel" (every channel converts the same). The problem is a mid-course engagement issue, not an acquisition or pricing issue.

---

### Finding 2 — Course Category Is Not the Main Differentiator

| Category | Completion % | Pass Rate % |
|---|---|---|
| Statistics | 30.2 (lowest) | 60.2 |
| Excel | 31.0 | 58.5 (lowest) |
| Python | 31.9 | 59.8 |
| Data Engineering | 32.1 | 62.2 |
| SQL | 32.2 | 59.9 |
| Power BI | 32.3 (highest) | 62.7 (highest) |

**The insight:** The spread across categories is narrow (~2 points) — course subject matter is not the primary driver of completion. Statistics is weakest on completion; Excel is weakest on quiz pass rate; Power BI & Data Engineering perform best on both.

---

### Finding 3 — Advanced Courses Have the Highest Completion (Counter-Intuitive)

| Level | Completion % | Pass Rate % |
|---|---|---|
| Intermediate | 31.1 (lowest) | 59.6 |
| Beginner | 31.5 | 60.0 |
| **Advanced** | **32.9 (highest)** | **62.7 (highest)** |

**The insight:** Contrary to the assumption that harder courses get abandoned more, advanced-level courses show the *highest* completion and pass rates. This is likely a **self-selection effect** — students who commit to an advanced course are already more invested, while beginner courses attract casual/curious sign-ups who churn more easily.

---

### Finding 4 — Instructor Is the Strongest Differentiator, and Rating Is Misleading

Instructor-level completion rates range from **27.9% to 36.5%** (a ~8.6-point spread — far wider than the category or level spread). The correlation between instructor rating and completion rate is **negative (-0.17)**: instructors with the highest ratings (4.8–5.0) tend to cluster at the *lowest* completion rates.

**The insight:** Course rating (often collected early, before students disengage) is not a reliable proxy for whether an instructor actually gets students to finish. The platform would benefit from tracking completion-linked instructor quality metrics, not rating alone.

---

## 7. Dashboard

Designed as a single narrative arc — KPI overview at top, then the two objective storylines below it.

🔗 [Open Dashboard in Looker Studio →]([ISI_LINK_LOOKER_STUDIO_DI_SINI])

**Layout:**
- **Top row** — 6 KPI scorecards: Total Students, Active Courses, Total Enrollments, Completion Rate, Avg Quiz Score, Certificates Issued
- **Upper section** — Funnel Completion per Plan Type (grouped bar: Enrolled/Started/Completed)
- **Middle** — Completion Rate per Category (weighted, bar chart)
- **Bottom** — Instructor Rating vs. Completion Rate (bubble scatter, bubble size = total students)

---

## 8. Insights & Strategic Recommendations

> *Recommendations below are based on observed patterns in this dataset. Where future outcomes are discussed, they are framed as directional hypotheses requiring validation through experimentation, not guaranteed results.*

### 8.1 Key Findings Summary

**Objective 1 — Completion Funnel:**
1. **Mid-course engagement leak:** ~69% of students who start a course never finish it. The pattern is identical across plan types and acquisition channels — the fix lies in course/product design, not marketing or pricing.

**Objective 2 — Course & Instructor Performance:**
2. **Category & level are weak differentiators** (~2-point spread) — not where the platform should focus improvement effort.
3. **Advanced courses retain better** — a self-selection signal suggesting beginner courses need stronger onboarding/commitment mechanisms.
4. **Instructor quality is the strongest lever** (8.6-point spread) — and current rating-based quality signals are actively misleading (negative correlation with completion).

---

### 8.2 Recommendation Pillar 1 — Mid-Course Engagement Intervention

**Problem:** ~69% of "started" students never complete, uniformly across segments.

**Approach:** Since the leak is not segment-specific, prioritize a platform-wide intervention rather than targeted campaigns.

| Element | Detail |
|---|---|
| Hypothesis | A milestone/progress-nudge system (e.g., reminder email at 25%/50% completion) may reduce mid-course drop-off |
| Design | A/B test — Group A (no nudge) vs. Group B (milestone email/notification) |
| Randomization unit | student_id |
| Primary metric | Started → Completed conversion rate |
| Guardrail metric | Unsubscribe / notification opt-out rate |
| Exit criteria | If lift is negligible after test window, investigate content-pacing issues (e.g., course length, video density) instead |

---

### 8.3 Recommendation Pillar 2 — Instructor Quality Re-Calibration

**Problem:** Rating is a poor proxy for instructor effectiveness; the platform may be over-promoting instructors who don't drive real learning outcomes.

| Element | Detail |
|---|---|
| Action | Introduce a "Completion-Adjusted Instructor Score" alongside star rating in instructor listings |
| Immediate step | Flag instructors with rating ≥ 4.8 but completion rate < 30% (e.g., INST25) for content/pedagogy review |
| Best-practice sharing | Study top completion-rate instructors (e.g., INST16 at 36.5%) to identify replicable teaching patterns |
| Success threshold | Reduced gap between top and bottom instructor completion rates over 2 quarters |

---

### 8.4 Recommendation Pillar 3 — Beginner Course Onboarding

**Problem:** Beginner-level courses show the weakest self-selection effect and are most exposed to casual-signup churn.

| Element | Detail |
|---|---|
| Action | Add a short "commitment" step at beginner-course enrollment (e.g., goal-setting prompt, expected time investment preview) |
| Design | A/B test — Group A (standard enrollment) vs. Group B (commitment step) |
| Primary metric | Enrolled → Started → Completed conversion for beginner-level courses |
| Exit criteria | If no measurable lift, deprioritize in favor of Pillar 1 (broader engagement fix) |

---

## Limitations & Methodology Notes

1. **Synthetic dataset:** SkillAju is a generated dataset designed for SQL practice (window functions, aggregation, multi-table joins). All 5 tables were found to be fully clean (0 rejected rows) — real-world platform data would likely require more extensive cleaning.
2. **Certificate = Completion:** Since `certificate_issued = TRUE` occurs in 100% of `completion_pct = 100` cases, "Certified" was treated as informationally equivalent to "Completed" throughout this analysis rather than as a separate funnel signal.
3. **Weighted vs. simple averages:** Category and instructor metrics use enrollment-weighted averages to avoid small-sample distortion (e.g., a category/instructor with very few students skewing the ranking).
4. **Correlation, not causation:** The negative correlation (-0.17) between instructor rating and completion rate is suggestive, not conclusive, given the small instructor sample (n=22 with published courses). It should be treated as a hypothesis for further investigation, not a confirmed causal relationship.
5. **A/B tests are forward-looking:** Historical data cannot be retroactively randomized. All experiment designs in Section 8 are recommendations to execute going forward, not results already observed.

---

*Dataset: [SkillAju: Marketplace Kelas Online — Ngulik Data](https://ngulikdata.com/)*

*SQL: BigQuery Sandbox (project: `skillaju-project`, dataset: `skillaju_raw`)*

*EDA: [Python for EDA — Google Colab]([ISI_LINK_COLAB_DI_SINI])*

*Dashboard: [Looker Studio]([ISI_LINK_LOOKER_STUDIO_DI_SINI])*
