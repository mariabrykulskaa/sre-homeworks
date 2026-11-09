import pytest

from taskflow.errors import HttpError
from taskflow.validate import parse_id, parse_pagination, validate_project, validate_task


def status_of(fn, *args, **kwargs):
    with pytest.raises(HttpError) as info:
        fn(*args, **kwargs)
    return info.value.status


def test_parse_id_accepts_positive_integers():
    assert parse_id("1") == 1
    assert parse_id("999999999999999") == 999_999_999_999_999
    assert parse_id(7) == 7


@pytest.mark.parametrize("bad", ["0", "007", "-1", "1.5", "abc", "", "1 ", ["1", "2"], "9" * 16, True])
def test_parse_id_rejects_zero_leading_zeros_and_garbage(bad):
    assert status_of(parse_id, bad) == 400


def test_parse_pagination_defaults_cap_and_offset():
    assert parse_pagination({}) == (100, 0)
    assert parse_pagination({"limit": "5", "offset": "10"}) == (5, 10)
    assert parse_pagination({"limit": "9999"}) == (500, 0)
    assert status_of(parse_pagination, {"limit": "0"}) == 400
    assert status_of(parse_pagination, {"offset": "-1"}) == 400
    assert status_of(parse_pagination, {"offset": "100001"}) == 400


def test_validate_project_requires_name_on_create():
    assert validate_project({"name": "  Диплом  "}) == {"name": "Диплом", "description": None}
    for body in ({}, {"name": ""}, {"name": "   "}, {"name": 42}, [], None):
        assert status_of(validate_project, body) == 400


def test_validate_project_null_is_absent_and_partial_needs_a_field():
    assert validate_project({"name": "a", "description": None}) == {"name": "a", "description": None}
    assert validate_project({"description": "x"}, partial=True)["description"] == "x"
    assert status_of(validate_project, {}, partial=True) == 400
    assert status_of(validate_project, {"name": "  "}, partial=True) == 400


def test_validate_project_length_counts_characters_and_rejects_bad_unicode():
    assert validate_project({"name": "я" * 120})["name"] == "я" * 120
    assert status_of(validate_project, {"name": "я" * 121}) == 400
    assert status_of(validate_project, {"name": "a\x00b"}) == 400
    assert status_of(validate_project, {"name": "\ud800"}) == 400


def test_validate_task_full_and_required_fields():
    task = validate_task({"project_id": "3", "title": "T", "status": "done", "description": "d"})
    assert task == {"project_id": 3, "title": "T", "status": "done", "description": "d"}
    assert status_of(validate_task, {"title": "T"}) == 400
    assert status_of(validate_task, {"project_id": "1"}) == 400


def test_validate_task_status_must_be_known():
    assert status_of(validate_task, {"project_id": "1", "title": "T", "status": "unknown"}) == 400
    assert status_of(validate_task, {"status": 1}, partial=True) == 400


def test_validate_task_partial():
    assert validate_task({"status": "done"}, partial=True)["status"] == "done"
    assert status_of(validate_task, {}, partial=True) == 400
