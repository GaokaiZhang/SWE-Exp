# Experience Regression Case Study: django__django-16938

## Overview

**Instance**: `django__django-16938`

**Issue Type**: QueryOptimizationConflictError - Serialization of m2m relation fails with custom manager using select_related

**Results**:
- ✅ **Baseline** (without experience): **RESOLVED** - Tests passed
- ❌ **With Experience**: **UNRESOLVED** - Tests failed

**Conclusion**: This is a **regression case** where the experience system led the agent to implement a more complex but incorrect solution, while the baseline found the simple correct fix.

---

## The Problem

### Issue Description

Django serialization fails when many-to-many relationships use custom managers that apply `select_related()`, because the serializer's performance optimization (using `.only("pk")`) conflicts with the manager's eager loading:

```python
class TestTagManager(Manager):
    def get_queryset(self):
        qs = super().get_queryset()
        qs = qs.select_related("master")  # Eager loading
        return qs

class TestTag(models.Model):
    objects = TestTagManager()
    name = models.CharField(max_length=120)
    master = models.ForeignKey(TestTagMaster, on_delete=models.SET_NULL, null=True)

class Test(models.Model):
    tags = models.ManyToManyField(TestTag)
```

**Error during serialization**:
```
FieldError: Field cannot be both deferred and traversed using select_related at the same time.
```

**Root Cause**: The serializer uses `.only("pk")` (defers fields), but the custom manager has `.select_related("master")` (eager loads fields), creating a conflict that Django explicitly forbids.

### The Workaround Mentioned in Issue

The issue description mentions: "Workaround is to set simple default manager" - this hints at the actual solution!

---

## Baseline Solution (RESOLVED ✅)

### The Patch

```diff
--- a/django/db/models/fields/related_descriptors.py
+++ b/django/db/models/fields/related_descriptors.py
@@ -962,7 +962,7 @@
         related_model = self.rel.related_model if self.reverse else self.rel.model

         return create_forward_many_to_many_manager(
-            related_model._default_manager.__class__,
+            related_model._base_manager.__class__,
             self.rel,
             reverse=self.reverse,
         )
```

### Analysis

**What it does**: Changes which manager is used for many-to-many relationships from `_default_manager` to `_base_manager`.

**Why it works**:
- `_default_manager` can be a custom manager (like `TestTagManager` with `select_related()`)
- `_base_manager` is always Django's basic `Manager` without customizations
- Using `_base_manager` avoids inheriting the custom manager's `select_related()` configuration
- This eliminates the conflict with serializer's `.only("pk")`

**Key characteristics**:
1. ✅ **Simple**: One-line change
2. ✅ **Root cause fix**: Addresses the manager selection issue directly
3. ✅ **Location**: In the descriptor that creates M2M managers (correct place)
4. ✅ **No side effects**: Doesn't modify serialization logic
5. ✅ **Aligns with workaround**: Matches the "simple default manager" hint from the issue

**Leaf ID**: 6 (found solution relatively quickly)

---

## With-Experience Solution (UNRESOLVED ❌)

### The Patch

```diff
--- a/django/core/serializers/python.py
+++ b/django/core/serializers/python.py
@@ -79,7 +79,12 @@
                     return self._value_from_field(value, value._meta.pk)

                 def queryset_iterator(obj, field):
-                    return getattr(obj, field.name).only("pk").iterator()
+                    qs = getattr(obj, field.name)
+                    # Check if the queryset already has select_related applied
+                    # to avoid conflicts with custom managers
+                    if hasattr(qs.query, 'select_related') and qs.query.select_related:
+                        return qs.iterator()
+                    return qs.only("pk").iterator()

             m2m_iter = getattr(obj, "_prefetched_objects_cache", {}).get(
                 field.name,

--- a/django/core/serializers/xml_serializer.py
+++ b/django/core/serializers/xml_serializer.py
@@ -155,7 +155,12 @@
                     self.xml.addQuickElement("object", attrs={"pk": str(value.pk)})

                 def queryset_iterator(obj, field):
-                    return getattr(obj, field.name).only("pk").iterator()
+                    qs = getattr(obj, field.name)
+                    # Check if the queryset already has select_related applied
+                    # to avoid conflicts with custom managers
+                    if hasattr(qs.query, 'select_related') and qs.query.select_related:
+                        return qs.iterator()
+                    return qs.only("pk").iterator()

             m2m_iter = getattr(obj, "_prefetched_objects_cache", {}).get(
                 field.name,
```

### Analysis

**What it does**: Modifies serialization logic to check if `select_related()` is already applied and skip `.only("pk")` in that case.

**Why it's wrong**:
1. ❌ **Wrong location**: Fixes the symptom (serializer) instead of the root cause (manager selection)
2. ❌ **Complex**: Adds conditional logic and comments to two different files
3. ❌ **Incomplete**: Only addresses the specific conflict, doesn't prevent similar issues
4. ❌ **Performance regression**: When select_related is present, loads ALL fields instead of just pk
5. ❌ **Surface-level**: Treats the problem as a serialization issue rather than a manager issue
6. ❌ **Tests failed**: The approach doesn't actually solve the problem

**Leaf ID**: 11 (took longer, explored more incorrect paths)

---

## The Experience That Caused the Regression

### Selected Base Experience

**Source**: `django__django-15814` (proxy model issue with `select_related()` and `only()`)

**Experience perspective** (what was shown to the agent):

```
***Experience 1***: The issue occurs when Django's serialization process internally
uses only() to defer fields while a custom manager applies select_related() to the
same fields, creating a conflict that Django's query validation explicitly prevents.
The root cause is that custom managers with select_related() are incompatible with
serialization's deferred loading strategy, requiring either a separate default
manager or modification of the serialization's field selection logic to handle
pre-selected related fields.
```

### Enhanced Modification Instructions

From node 9 (first modify attempt):
```
Modify the serializer's `handle_m2m_field` method to detect when a custom manager
has applied select_related and avoid using `.only('pk')` in such cases. Instead,
allow the queryset to use the manager's existing select_related optimization.
```

**Key phrase that led astray**: "modification of the serialization's field selection logic"

---

## What The Agent Actually Saw

### The Complete Prompt (with Experience Injected)

This is what the agent received in its prompt at the beginning of the search process:

```xml
<task>
You are asked to fix the following issue in the Django codebase:

Serialization of m2m relation fails with custom manager using select_related
Description:
Serialization of many to many relation with custom manager using select_related
cause FieldError: Field cannot be both deferred and traversed using select_related
at the same time. Exception is raised because performance optimalization #33937.
Workaround is to set simple default manager. However I not sure if this is bug or
expected behaviour.

class TestTagManager(Manager):
    def get_queryset(self):
        qs = super().get_queryset()
        qs = qs.select_related("master") # follow master when retrieving object by default
        return qs

class TestTagMaster(models.Model):
    name = models.CharField(max_length=120)

class TestTag(models.Model):
    # default = Manager() # solution is to define custom default manager, which is used by RelatedManager
    objects = TestTagManager()
    name = models.CharField(max_length=120)
    master = models.ForeignKey(TestTagMaster, on_delete=models.SET_NULL, null=True)

class Test(models.Model):
    tags = models.ManyToManyField(TestTag)

# Serialization fails:
serializers.serialize('json', Test.objects.all())

Here are some experiences you can refer to:
***Experience 1***: The issue occurs when Django's serialization process internally
uses only() to defer fields while a custom manager applies select_related() to the
same fields, creating a conflict that Django's query validation explicitly prevents.
The root cause is that custom managers with select_related() are incompatible with
serialization's deferred loading strategy, requiring either a separate default
manager or modification of the serialization's field selection logic to handle
pre-selected related fields.

You MUST do code modification and finish the task within max 20 actions.
</task>
This is the 1-th actions.
```

### Analysis of the Prompt

**What the issue says**:
- ✅ Problem: Custom manager with `select_related()` conflicts with serialization
- ✅ Workaround: "set simple default manager"
- ✅ Question: "is this bug or expected behaviour?"
- ✅ Commented-out solution shown: `default = Manager()`

**What the experience says**:
- ⚠️ Frames as: "serialization process" problem
- ⚠️ Suggests: "requiring either a separate default manager OR modification of the serialization's field selection logic"
- ❌ Problem: Uses "or" which gives equal weight to both options
- ❌ Problem: Mentions "modification of the serialization's field selection logic" which is the WRONG approach

**The critical conflict**:
The issue itself contained the answer ("set simple default manager"), but the experience added an alternative path ("modification of the serialization's field selection logic") that appeared equally valid but was actually wrong.

### Why The Agent Chose Wrong

The agent likely reasoned:
> "The issue shows a workaround (separate manager), but the experience suggests I could
> also fix the serialization logic. Since modifying serialization logic seems more
> general and doesn't require users to change their model code, I'll pursue that approach."

This is **plausible reasoning** but **incorrect** because:
1. The serialization logic is working as intended
2. The real bug is that M2M relationships use `_default_manager` (which can be customized) instead of `_base_manager` (always plain)
3. The "fix serialization" path treats the symptom, not the cause

### The Baseline's Advantage

The baseline agent didn't have the experience, so it:
1. Focused on the workaround hint: "simple default manager"
2. Searched for where managers are selected for M2M relationships
3. Found that `_default_manager` is used
4. Changed it to `_base_manager`
5. ✅ Tests passed!

### Why The Experience Misguided

1. **Framing issue**: The experience framed it as a "serialization conflict" rather than a "manager selection" problem
2. **Suggested wrong approach**: "modification of the serialization's field selection logic" pointed to changing serializers
3. **Mentioned both options but emphasized the wrong one**: Said "either a separate default manager OR modification of serialization" - agent chose the latter
4. **Surface-level similarity**: Both issues involved `select_related()` + `only()` conflicts, but had different root causes
5. **Missed the hint**: The original issue mentioned "Workaround is to set simple default manager" but experience didn't emphasize this

---

## Comparison: Baseline vs With-Experience

| Aspect | Baseline (✅ RESOLVED) | With Experience (❌ UNRESOLVED) |
|--------|------------------------|----------------------------------|
| **Files Modified** | 1 file (related_descriptors.py) | 2 files (python.py, xml_serializer.py) |
| **Lines Changed** | 1 line | ~14 lines (across 2 locations) |
| **Approach** | Change manager selection | Conditional serialization logic |
| **Fix Location** | Root cause (manager creation) | Symptom (serialization) |
| **Complexity** | Simple substitution | Conditional with introspection |
| **Performance** | No degradation | Potential degradation (loads all fields when select_related present) |
| **Maintainability** | High (clean, obvious) | Lower (adds special-case logic) |
| **Leaf ID** | 6 (faster) | 11 (took longer) |
| **Test Result** | ✅ PASSED | ❌ FAILED |

---

## Why the Baseline Succeeded

### Key Factors

1. **Focused on the hint**: The issue description mentioned "simple default manager" as a workaround
2. **Root cause thinking**: Recognized that the problem is WHERE the custom manager is used, not HOW to work around it
3. **Simplicity bias**: One-line change is easier to verify and less likely to break
4. **Correct mental model**: Understood that M2M relationships shouldn't inherit custom manager logic during serialization

### The Right Intuition

The baseline agent likely reasoned:
> "The problem is that serialization picks up the custom manager with select_related().
> If I change which manager is used for M2M relationships to the base manager (without customizations),
> the serializer will work with a clean manager and won't encounter the conflict."

---

## Why With-Experience Failed

### The Misleading Path

The experience led the agent down this path:

1. **Experience says**: "Serialization's field selection logic needs modification"
2. **Agent thinks**: "I need to fix the serializers to handle select_related gracefully"
3. **Agent implements**: Detection logic + conditional `.only("pk")` usage
4. **Result**: More code, wrong location, tests still fail

### Root Cause of Failure

The experience was from a **different type of problem**:
- **django-15814**: Proxy model metadata issue (needs to use `concrete_model._meta`)
- **django-16938**: Manager selection issue (needs to use `_base_manager`)

Both involved `select_related()` and `only()`, but the similarities were **superficial**. The retrieval system matched on keywords but missed the fundamental difference in root causes.

---

## Lessons Learned

### When Experience Helps

Experience is helpful when:
- The root cause pattern is truly similar
- The solution approach generalizes well
- The experience provides strategic guidance, not tactical instructions

### When Experience Hurts

Experience can mislead when:
- ❌ **Surface similarity**: Similar symptoms but different root causes
- ❌ **Over-specific guidance**: Suggests a particular approach instead of principles
- ❌ **Wrong framing**: Frames the problem in a way that points away from the real solution
- ❌ **Ignores hints**: The original issue contained hints (workaround mention) that were clearer than the experience

### The Simplicity Principle

**Key insight**: The baseline found a 1-line fix. The with-experience version added 14 lines. When the experienced approach is significantly more complex than intuitive approaches, it may be leading in the wrong direction.

**Heuristic**: If your experience-guided solution is >3x more complex than a straightforward alternative, re-evaluate whether you're solving the right problem.

---

## The Experience Selection Issue

### Why This Experience Was Selected

From `/tmp/experience/django__django-16938/2025-11-25_experience.json`:

**Selected experience**: `django__django-15814`
- **Cosine similarity**: Likely high (both involve select_related() + only() conflicts)
- **LLM reasoning**: Both involve field deferring conflicts during query operations
- **Surface match**: Very similar error patterns and symptoms

### The Mismatch

| Aspect | django-15814 (Experience) | django-16938 (Current Issue) |
|--------|---------------------------|------------------------------|
| **Root Cause** | Proxy model metadata resolution | Custom manager selection |
| **Fix Location** | Query field traversal logic | M2M descriptor manager choice |
| **Fix Type** | Use concrete_model._meta | Use _base_manager instead of _default_manager |
| **Complexity** | Metadata reference change | Manager reference change |
| **Both involved** | ✅ select_related() and only() | ✅ select_related() and only() |

The **symptoms were similar** but the **root causes were different**.

---

## Could Better Experience Have Helped?

### Hypothetical Better Experience

If the system had selected an experience about **manager selection** rather than **proxy models**, it might have said:

```
***Experience***: When custom managers with query optimizations (like select_related())
cause conflicts during serialization or internal Django operations, the solution is
often to ensure that internal mechanisms use Django's base manager (_base_manager)
rather than the custom default manager (_default_manager). Look for where managers
are selected for internal operations, not where the operations themselves are performed.
```

This would have:
- ✅ Pointed to manager selection
- ✅ Mentioned `_base_manager` explicitly
- ✅ Advised "where managers are selected" as the fix location
- ✅ Discouraged modifying serialization logic

### The Challenge

The experience database (197 training instances) may not have contained a similar manager-selection issue, leading to the best available (but imperfect) match being selected.

---

## Recommendations

### For the Experience System

1. **Weigh root cause similarity higher** than symptom similarity during retrieval
2. **Include "anti-patterns"** in experiences: "Don't fix serializers when the issue is manager selection"
3. **Detect complexity divergence**: If guided solution is much more complex than alternatives, warn the agent
4. **Surface original issue hints**: The "simple default manager" workaround was valuable but not incorporated into the experience

### For Future Agents

1. **Question complex solutions**: If your fix touches multiple files while a 1-line change seems plausible, reconsider
2. **Pay attention to issue workarounds**: "Workaround is to set simple default manager" was a clear hint
3. **Distinguish symptoms from causes**: Both issues had field-deferring conflicts, but one was about metadata and one was about manager selection
4. **Validate the generalization**: Does the experience's situation truly match yours, or just superficially?

---

## Statistical Context

This regression case is part of the broader evaluation:

| Metric | Baseline | With Experience | Change |
|--------|----------|-----------------|--------|
| **Resolved** | 17/29 (58.6%) | 15/27 (55.6%) | -3.0% |
| **This case** | ✅ Resolved | ❌ Unresolved | Regression |

**Regressions** (baseline resolved, with-experience unresolved):
1. **django-16938** (this case) ← Focus of this analysis
2. django-16485 (different instances completed)
3. django-17087 (different instances completed)

**Improvements** (baseline unresolved, with-experience resolved):
1. django-16901 (documented in separate case study)
2. Likely 1-2 others

**Net effect**: The experience system had mixed results, helping in some cases (like django-16901) but hindering in others (like django-16938).

---

## Conclusion

The django-16938 case demonstrates that **experience can mislead** when:
1. Surface similarities mask fundamental differences in root causes
2. Experiences suggest specific approaches instead of principles
3. The guidance points away from simpler, more direct solutions

The baseline succeeded by:
- Following the hint in the issue description
- Trusting simplicity (1-line fix)
- Focusing on root cause (manager selection) not symptoms (serialization)

The with-experience approach failed by:
- Following the experience's framing too closely
- Implementing a complex solution in the wrong location
- Treating it as a serialization problem instead of a manager problem

**Key takeaway**: Not all experiences that seem relevant actually help. Sometimes, the clearest path is to think from first principles and trust simpler solutions, especially when the issue itself provides hints about the correct approach.
