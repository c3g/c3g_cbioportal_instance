### opa test opa/c3g_cbioportal/ -v
package c3g_cbioportal.authz_test

import data.c3g_cbioportal.authz

studies := {
	"study_a": ["group-a"],
	"study_ab": ["group-a", "group-b"],
	"study_none": [],
}

admins := ["c3g-admins"]

test_member_can_view if {
	authz.allow with input as {"action": "view_study", "study": "study_a", "groups": ["group-a"]}
		with data.c3g_cbioportal.study_groups as studies
		with data.c3g_cbioportal.admin_groups as admins
}

test_other_group_denied if {
	not authz.allow with input as {"action": "view_study", "study": "study_a", "groups": ["group-b"]}
		with data.c3g_cbioportal.study_groups as studies
		with data.c3g_cbioportal.admin_groups as admins
}

test_admin_sees_listed_study if {
	authz.allow with input as {"action": "view_study", "study": "study_none", "groups": ["c3g-admins"]}
		with data.c3g_cbioportal.study_groups as studies
		with data.c3g_cbioportal.admin_groups as admins
}

test_unlisted_study_denied_even_for_admin if {
	not authz.allow with input as {"action": "view_study", "study": "not_in_policy", "groups": ["c3g-admins"]}
		with data.c3g_cbioportal.study_groups as studies
		with data.c3g_cbioportal.admin_groups as admins
}

test_no_groups_denied if {
	not authz.allow with input as {"action": "view_study", "study": "study_a", "groups": []}
		with data.c3g_cbioportal.study_groups as studies
		with data.c3g_cbioportal.admin_groups as admins
}

test_other_action_denied if {
	not authz.allow with input as {"action": "delete_study", "study": "study_a", "groups": ["group-a"]}
		with data.c3g_cbioportal.study_groups as studies
		with data.c3g_cbioportal.admin_groups as admins
}

test_study_access_table if {
	t := authz.study_access with data.c3g_cbioportal.study_groups as studies
		with data.c3g_cbioportal.admin_groups as admins
	t == {
		"study_a": {"group-a", "c3g-admins"},
		"study_ab": {"group-a", "group-b", "c3g-admins"},
		"study_none": {"c3g-admins"},
	}
}
