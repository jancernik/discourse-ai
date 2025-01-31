#frozen_string_literal: true

RSpec.describe DiscourseAi::AiBot::Commands::SearchCommand do
  before { SearchIndexer.enable }
  after { SearchIndexer.disable }

  let(:bot_user) { User.find(DiscourseAi::AiBot::EntryPoint::GPT3_5_TURBO_ID) }
  fab!(:admin)
  fab!(:parent_category) { Fabricate(:category, name: "animals") }
  fab!(:category) { Fabricate(:category, parent_category: parent_category, name: "amazing-cat") }
  fab!(:tag_funny) { Fabricate(:tag, name: "funny") }
  fab!(:tag_sad) { Fabricate(:tag, name: "sad") }
  fab!(:tag_hidden) { Fabricate(:tag, name: "hidden") }
  fab!(:staff_tag_group) do
    tag_group = Fabricate.build(:tag_group, name: "Staff only", tag_names: ["hidden"])

    tag_group.permissions = [
      [Group::AUTO_GROUPS[:staff], TagGroupPermission.permission_types[:full]],
    ]
    tag_group.save!
    tag_group
  end
  fab!(:topic_with_tags) do
    Fabricate(:topic, category: category, tags: [tag_funny, tag_sad, tag_hidden])
  end

  before { SiteSetting.ai_bot_enabled = true }

  it "can properly list options" do
    options = described_class.options.sort_by(&:name)
    expect(options.length).to eq(2)
    expect(options.first.name.to_s).to eq("base_query")
    expect(options.first.localized_name).not_to include("Translation missing:")
    expect(options.first.localized_description).not_to include("Translation missing:")

    expect(options.second.name.to_s).to eq("max_results")
    expect(options.second.localized_name).not_to include("Translation missing:")
    expect(options.second.localized_description).not_to include("Translation missing:")
  end

  describe "#process" do
    it "can retreive options from persona correctly" do
      persona =
        Fabricate(
          :ai_persona,
          allowed_group_ids: [Group::AUTO_GROUPS[:admins]],
          commands: [["SearchCommand", { "base_query" => "#funny" }]],
        )
      Group.refresh_automatic_groups!

      bot = DiscourseAi::AiBot::Bot.as(bot_user, persona_id: persona.id, user: admin)
      search_post = Fabricate(:post, topic: topic_with_tags)

      bot_post = Fabricate(:post)

      search = described_class.new(bot: bot, post: bot_post, args: nil)

      results = search.process(order: "latest")
      expect(results[:rows].length).to eq(1)

      search_post.topic.tags = []
      search_post.topic.save!

      # no longer has the tag funny
      results = search.process(order: "latest")
      expect(results[:rows].length).to eq(0)
    end

    it "can handle no results" do
      post1 = Fabricate(:post, topic: topic_with_tags)
      search = described_class.new(bot: nil, post: post1, args: nil)

      results = search.process(query: "order:fake ABDDCDCEDGDG")

      expect(results[:args]).to eq({ query: "order:fake ABDDCDCEDGDG" })
      expect(results[:rows]).to eq([])
    end

    describe "semantic search" do
      let (:query) {
        "this is an expanded search"
      }
      after { DiscourseAi::Embeddings::SemanticSearch.clear_cache_for(query) }

      it "supports semantic search when enabled" do
        SiteSetting.ai_embeddings_semantic_search_enabled = true
        SiteSetting.ai_embeddings_discourse_service_api_endpoint = "http://test.com"

        WebMock.stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
          status: 200,
          body: JSON.dump(OpenAiCompletionsInferenceStubs.response(query)),
        )

        hyde_embedding = [0.049382, 0.9999]
        EmbeddingsGenerationStubs.discourse_service(
          SiteSetting.ai_embeddings_model,
          query,
          hyde_embedding,
        )

        post1 = Fabricate(:post, topic: topic_with_tags)
        search = described_class.new(bot: nil, post: post1, args: nil)

        DiscourseAi::Embeddings::VectorRepresentations::AllMpnetBaseV2
          .any_instance
          .expects(:asymmetric_topics_similarity_search)
          .returns([post1.topic_id])

        results =
          DiscourseAi::Completions::Llm.with_prepared_responses(["<ai>#{query}</ai>"]) do
            search.process(search_query: "hello world, sam", status: "public")
          end

        expect(results[:args]).to eq({ search_query: "hello world, sam", status: "public" })
        expect(results[:rows].length).to eq(1)
      end
    end

    it "supports subfolder properly" do
      Discourse.stubs(:base_path).returns("/subfolder")

      post1 = Fabricate(:post, topic: topic_with_tags)

      search = described_class.new(bot: nil, post: post1, args: nil)

      results = search.process(limit: 1, user: post1.user.username)
      expect(results[:rows].to_s).to include("/subfolder" + post1.url)
    end

    it "returns rich topic information" do
      post1 = Fabricate(:post, like_count: 1, topic: topic_with_tags)
      search = described_class.new(bot: nil, post: post1, args: nil)
      post1.topic.update!(views: 100, posts_count: 2, like_count: 10)

      results = search.process(user: post1.user.username)

      row = results[:rows].first
      category = row[results[:column_names].index("category")]

      expect(category).to eq("animals > amazing-cat")

      tags = row[results[:column_names].index("tags")]
      expect(tags).to eq("funny, sad")

      likes = row[results[:column_names].index("likes")]
      expect(likes).to eq(1)

      username = row[results[:column_names].index("username")]
      expect(username).to eq(post1.user.username)

      likes = row[results[:column_names].index("topic_likes")]
      expect(likes).to eq(10)

      views = row[results[:column_names].index("topic_views")]
      expect(views).to eq(100)

      replies = row[results[:column_names].index("topic_replies")]
      expect(replies).to eq(1)
    end

    it "scales results to number of tokens" do
      SiteSetting.ai_bot_enabled_chat_bots = "gpt-3.5-turbo|gpt-4|claude-2"

      post1 = Fabricate(:post)

      gpt_3_5_turbo =
        DiscourseAi::AiBot::Bot.as(User.find(DiscourseAi::AiBot::EntryPoint::GPT3_5_TURBO_ID))
      gpt4 = DiscourseAi::AiBot::Bot.as(User.find(DiscourseAi::AiBot::EntryPoint::GPT4_ID))
      claude = DiscourseAi::AiBot::Bot.as(User.find(DiscourseAi::AiBot::EntryPoint::CLAUDE_V2_ID))

      expect(described_class.new(bot: claude, post: post1, args: nil).max_results).to eq(60)
      expect(described_class.new(bot: gpt_3_5_turbo, post: post1, args: nil).max_results).to eq(40)
      expect(described_class.new(bot: gpt4, post: post1, args: nil).max_results).to eq(20)

      persona =
        Fabricate(
          :ai_persona,
          commands: [["SearchCommand", { "max_results" => 6 }]],
          enabled: true,
          allowed_group_ids: [Group::AUTO_GROUPS[:trust_level_0]],
        )

      Group.refresh_automatic_groups!

      custom_bot = DiscourseAi::AiBot::Bot.as(bot_user, persona_id: persona.id, user: admin)

      expect(described_class.new(bot: custom_bot, post: post1, args: nil).max_results).to eq(6)
    end

    it "can handle limits" do
      post1 = Fabricate(:post, topic: topic_with_tags)
      _post2 = Fabricate(:post, user: post1.user)
      _post3 = Fabricate(:post, user: post1.user)

      # search has no built in support for limit: so handle it from the outside
      search = described_class.new(bot: nil, post: post1, args: nil)

      results = search.process(limit: 2, user: post1.user.username)

      expect(results[:rows].length).to eq(2)

      # just searching for everything
      results = search.process(order: "latest_topic")
      expect(results[:rows].length).to be > 1
    end
  end
end
