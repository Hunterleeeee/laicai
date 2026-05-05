from __future__ import annotations

import pytest

from harness.intent import IntentRouter


@pytest.fixture
def router():
    return IntentRouter()


def test_route_create_skill(router):
    result = router.route("做一个skill，先查笔记再抓网页")
    assert result.name == "create_skill"
    assert result.confidence >= 0.9


def test_route_publish_skill(router):
    result = router.route("发布skill")
    assert result.name == "publish_skill"


def test_route_run_skill(router):
    result = router.route("用 skill website-research 总结这个网站")
    assert result.name == "run_skill"


def test_route_switch_model_api(router):
    result = router.route("切到 API 模型，用 gpt-4.1-mini")
    assert result.name == "switch_model_api"


def test_route_switch_model_local(router):
    result = router.route("切回本地")
    assert result.name == "switch_model_local"


def test_route_research_url(router):
    result = router.route("研究 https://example.com 并保存")
    assert result.name == "research_url"
    assert result.url == "https://example.com"


def test_route_generate_quiz(router):
    result = router.route("根据最近笔记出题并保存")
    assert result.name == "generate_quiz"


def test_route_generate_flashcards(router):
    result = router.route("根据最近笔记做闪卡")
    assert result.name == "generate_flashcards"


def test_route_build_study_plan(router):
    result = router.route("给我一个学习计划")
    assert result.name == "build_study_plan"


def test_route_daily_review(router):
    result = router.route("今日复盘草案")
    assert result.name == "daily_review"


def test_route_review(router):
    result = router.route("复盘")
    assert result.name == "review"


def test_route_ask_default(router):
    result = router.route("随便问个问题")
    assert result.name == "ask"
    assert result.confidence < 0.7


def test_extract_url(router):
    url = router._extract_url("Check out https://example.com/path?q=1")
    assert url == "https://example.com/path?q=1"
