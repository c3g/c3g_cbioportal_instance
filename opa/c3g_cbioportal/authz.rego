################################################################################
### c3g_cbioportal_instance - study access policy (OPA, Rego v1)
### The real copy lives in the private c3g-opa-policies repo, folder c3g_cbioportal/
### This copy + data.json (placeholder groups only) are for local development.
### Load the PARENT folder, never this one: OPA puts data.json under the path of its
### folder (c3g_cbioportal/data.json -> data.c3g_cbioportal), same as a bundle built
### from the c3g-opa-policies repo root.
###   opa run --server --watch -b opa/
###   opa test opa/ -v
###
### Data (data.json, plain fields - NO outer "c3g_cbioportal" key, the folder gives it):
###   study_groups: {"<cancer_study_identifier>": ["<COmanage group>", ...]}
###   admin_groups: ["<COmanage group>", ...]   -> can see every LISTED study
### Group strings must match the COmanage `groups` claim exactly (ask the COmanage admin: short name or COU path).
###
### Queried by /app/entrypoint.sh (sync-access, every CBIO_OPA_SYNC_SECS and after each import):
###   POST /v1/data/c3g_cbioportal/authz/study_access  -> {"result": {"<study_id>": ["<group>", ...]}}
### A study not listed here is hidden from everyone (entrypoint writes OPA_DENY_GROUP).
################################################################################
package c3g_cbioportal.authz

# Single decision, same shape as the other C3G OPA policies:
# input {"action": "view_study", "study": "<study_id>", "groups": ["<group>", ...]}
default allow := false

allow if {
	input.action == "view_study"
	some g in input.groups
	g in study_access[input.study]
}

# Full table used by the cBioPortal access sync: study -> set of groups that may view it
study_access[study] := groups if {
	some study, listed in data.c3g_cbioportal.study_groups
	groups := {g | some g in listed} | {g | some g in data.c3g_cbioportal.admin_groups}
}
