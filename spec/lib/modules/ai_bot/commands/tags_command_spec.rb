#frozen_string_literal: true

RSpec.describe DiscourseAi::AiBot::Commands::TagsCommand do
  describe "#process" do
    it "can generate correct info" do
      SiteSetting.tagging_enabled = true

      Fabricate(:tag, name: "america", public_topic_count: 100)
      Fabricate(:tag, name: "not_here", public_topic_count: 0)

      info = DiscourseAi::AiBot::Commands::TagsCommand.new(bot: nil, args: nil).process

      expect(info.to_s).to include("america")
      expect(info.to_s).not_to include("not_here")
    end
  end
end
