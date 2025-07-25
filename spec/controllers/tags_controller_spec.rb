require "spec_helper"

describe TagsController do
  include LoginMacros
  include RedirectExpectationHelper

  wrangling_full_access_roles = %w[superadmin tag_wrangling].freeze
  wrangling_read_access_roles = (wrangling_full_access_roles + %w[policy_and_abuse]).freeze

  let(:user) { create(:tag_wrangler) }

  before { fake_login_known_user(user) }

  shared_examples "set last wrangling activity" do
    it "sets the last wrangling activity time to now", :frozen do
      expect(user.last_wrangling_activity.updated_at).to eq(Time.now.utc)
    end
  end

  describe "#create" do
    let(:tag_params) do
      { name: Faker::FunnyName.name, canonical: "0", type: "Character" }
    end

    context "successful creation" do
      before { post :create, params: { tag: tag_params } }

      it "creates a new, non-canonical, tag" do
        tag = Tag.last
        it_redirects_to_with_notice(edit_tag_path(tag), "Tag was successfully created.")
        expect(tag.name).to eq tag_params[:name]
        expect(tag).not_to be_canonical
      end

      include_examples "set last wrangling activity"
    end

    it "creates a new, canonical, tag" do
      tag_params[:canonical] = "1"

      post :create, params: { tag: tag_params }
      tag = Tag.last
      it_redirects_to_with_notice(edit_tag_path(tag), "Tag was successfully created.")

      expect(tag.name).to eq tag_params[:name]
      expect(tag).to be_canonical
    end

    it "cannot make changes to an existing tag when trying to create one" do
      existing_tag = create(:canonical_character, name: "Blake Belladonna")
      tag_params = { name: "Blâke Belladonna", canonical: "0", type: "Character" }

      post :create, params: { tag: tag_params }
      it_redirects_to_with_notice(edit_tag_path(existing_tag), "Tag already existed and was not modified.")

      existing_tag.reload
      expect(existing_tag.name).to eq "Blake Belladonna"
      expect(existing_tag).to be_canonical
    end
  end

  describe "wrangle" do
    context "when showing unwrangled freeforms for a fandom" do
      let(:fandom) { create(:fandom, canonical: true) }
      let(:freeform1) { create(:freeform, name: "beta") }
      let(:freeform2) { create(:freeform, name: "Omega") }
      let(:freeform3) { create(:freeform, name: "Alpha") }
      let(:freeform4) { create(:freeform, name: "an abo au") }

      before(:each) do
        create(:work,
               fandom_string: fandom.name,
               freeform_string: "#{freeform1.name}, #{freeform2.name},
               #{freeform3.name}, #{freeform4.name}")
        run_all_indexing_jobs
      end

      subject { get :wrangle, params: { id: fandom.name, show: "freeforms", status: "unwrangled" } }
      let(:success) do
        expect(assigns(:tags)).to include(freeform1)
      end

      it_behaves_like "an action only authorized admins can access", authorized_roles: wrangling_read_access_roles

      it "includes unwrangled freeforms" do
        get :wrangle, params: { id: fandom.name, show: "freeforms", status: "unwrangled" }
        expect(assigns(:tags)).to include(freeform1)
      end

      it "sorts tags in ascending order by name" do
        get :wrangle, params: { id: fandom.name, show: "freeforms", status: "unwrangled" }
        expect(assigns(:tags).pluck(:name)).to eq([freeform3.name,
                                                   freeform4.name,
                                                   freeform1.name,
                                                   freeform2.name])
      end
    end

    context "when showing canonical relationships for a character" do
      let(:character1) { create(:canonical_character, name: "A") }
      let(:relationship1) { create(:canonical_relationship, name: "A/B", taggings_count_cache: 1) }
      let(:relationship2) { create(:canonical_relationship, name: "A/C", taggings_count_cache: 2) }
      let(:relationship3) { create(:canonical_relationship, name: "A/D") }
      let(:relationship4) { create(:canonical_relationship, name: "A/E") }

      before do
        relationship1.add_association(character1)
        relationship2.add_association(character1)
        relationship3.add_association(character1)
        relationship4.add_association(character1)
        run_all_indexing_jobs
      end

      it "sorts tags by taggings count" do
        get :wrangle, params: { id: character1.name, show: "relationships", status: "canonical", sort_column: "taggings_count_cache", sort_direction: "DESC" }
        expect(assigns(:tags).pluck(:name)).to eq([relationship2.name,
                                                   relationship1.name,
                                                   relationship3.name,
                                                   relationship4.name])

        get :wrangle, params: { id: character1.name, show: "relationships", status: "canonical", sort_column: "taggings_count_cache", sort_direction: "ASC" }
        expect(assigns(:tags).pluck(:name)).to eq([relationship3.name,
                                                   relationship4.name,
                                                   relationship1.name,
                                                   relationship2.name])
      end
    end
  
    context "when showing unwrangled relationships for a character" do
      let(:character1) { create(:character, canonical: true) }
      let(:character2) { create(:character, canonical: true) }
      let(:relationship1) { create(:relationship) }
      let(:relationship2) { create(:relationship) }

      before do
        create(:work,
               character_string: character1.name,
               relationship_string: relationship1.name)
        create(:work,
               character_string: character2.name,
               relationship_string: relationship2.name)
        run_all_indexing_jobs
      end

      it "includes only relationships from works with that character tag" do
        get :wrangle, params: { id: character1.name, show: "relationships", status: "unwrangled" }
        expect(assigns(:tags)).to include(relationship1)
        expect(assigns(:tags)).not_to include(relationship2)
      end
    end
  end

  describe "mass_update" do
    before do
      @fandom1 = FactoryBot.create(:fandom, canonical: true)
      @fandom2 = FactoryBot.create(:fandom, canonical: true)
      @fandom3 = FactoryBot.create(:fandom, canonical: false)

      @freeform1 = FactoryBot.create(:freeform, canonical: false)
      @character1 = FactoryBot.create(:character, canonical: false)
      @character3 = FactoryBot.create(:character, canonical: false)
      @character2 = FactoryBot.create(:character, canonical: false, merger: @character3)
      @work = FactoryBot.create(:work,
                                fandom_string: @fandom1.name.to_s,
                                character_string: "#{@character1.name},#{@character2.name}",
                                freeform_string: @freeform1.name.to_s)
    end

    it "should redirect to the wrangle action for that tag" do
      expect(put(:mass_update, params: { id: @fandom1.name, show: "freeforms", status: "unwrangled" }))
        .to redirect_to wrangle_tag_path(id: @fandom1.name,
                                         show: "freeforms",
                                         status: "unwrangled",
                                         page: 1,
                                         sort_column: "name",
                                         sort_direction: "ASC")
    end

    subject { put :mass_update, params: { id: @fandom1.name, show: "freeforms", status: "unwrangled", fandom_string: @fandom2.name, selected_tags: [@freeform1.id] } }
    let(:success) do
      get :wrangle, params: { id: @fandom1.name, show: "freeforms", status: "unwrangled" }
      expect(assigns(:tags)).not_to include(@freeform1)

      @freeform1.reload
      expect(@freeform1.fandoms).to include(@fandom2)
    end

    it_behaves_like "an action only authorized admins can access", authorized_roles: wrangling_full_access_roles

    context "with one canonical and one noncanonical fandoms in the fandom string and a selected freeform" do
      before do
        put :mass_update, params: { id: @fandom1.name, show: "freeforms", status: "unwrangled", fandom_string: "#{@fandom2.name},#{@fandom3.name}", selected_tags: [@freeform1.id] }
      end

      it "updates the tags successfully" do
        @freeform1.reload
        expect(@freeform1.fandoms).to include(@fandom2)
        expect(@freeform1.fandoms).not_to include(@fandom3)
      end

      include_examples "set last wrangling activity"
    end

    context "with two canonical fandoms in the fandom string and a selected character" do
      before do
        put :mass_update, params: { id: @fandom1.name, show: "characters", status: "unwrangled", fandom_string: "#{@fandom1.name},#{@fandom2.name}", selected_tags: [@character1.id] }
      end

      it "updates the tags successfully" do
        @character1.reload
        expect(@character1.fandoms).to include(@fandom1)
        expect(@character1.fandoms).to include(@fandom2)
      end

      include_examples "set last wrangling activity"
    end

    context "with a canonical fandom in the fandom string, a selected unwrangled character, and the same character to be made canonical" do
      before do
        put :mass_update, params: { id: @fandom1.name, show: "characters", status: "unwrangled", fandom_string: @fandom1.name.to_s, selected_tags: [@character1.id], canonicals: [@character1.id] }
      end

      it "updates the tags successfully" do
        @character1.reload
        expect(@character1.fandoms).to include(@fandom1)
        expect(@character1).to be_canonical
      end

      include_examples "set last wrangling activity"
    end

    context "with a canonical fandom in the fandom string, a selected synonym character, and the same character to be made canonical" do
      before do
        put :mass_update, params: { id: @fandom1.name, show: "characters", status: "unfilterable", fandom_string: @fandom2.name.to_s, selected_tags: [@character2.id], canonicals: [@character2.id] }
      end

      it "updates the tags successfully" do
        @character2.reload
        expect(@character2.fandoms).to include(@fandom2)
        expect(@character2).not_to be_canonical
      end

      include_examples "set last wrangling activity"
    end

    context "removing an associated tag" do
      before do
        put :mass_update, params: { id: @character3.name, remove_associated: [@character2.id] }
      end

      it "updates the tags successfully" do
        expect(flash[:notice]).to eq "The following tags were successfully removed: #{@character2.name}"
        expect(flash[:error]).to be_nil
        expect(@character3.mergers).to eq []
      end

      include_examples "set last wrangling activity"
    end
  end

  describe "feed" do
    it "You can only get a feed on Fandom, Character and Relationships" do
      @tag = FactoryBot.create(:banned, canonical: false)
      get :feed, params: { id: @tag.id, format: :atom }
      it_redirects_to(tag_works_path(tag_id: @tag.name))
    end

    context "when tag doesn't exist" do
      it "raises an error" do
        expect do
          get :feed, params: { id: "notatag", format: "atom" }
        end.to raise_error ActiveRecord::RecordNotFound
      end
    end
  end

  describe "new" do 
    subject { get :new }
    let(:success) do
      expect(response).to have_http_status(:success)
    end

    it_behaves_like "an action only authorized admins can access", authorized_roles: wrangling_full_access_roles

    context "when logged in as a tag wrangler" do
      it "allows access" do
        get :new
        expect(response).to have_http_status(:success)
      end
    end
  end

  describe "show" do   
    context "displays the tag information page" do
      let(:tag) { create(:tag) }
      
      subject { get :show, params: { id: tag.name } }
      let(:success) do
        expect(response).to have_http_status(:success)
      end

      it "for guests" do
        subject
        success
      end

      it "for users" do
        fake_login
        subject
        success
      end
      
      it "for admins" do
        fake_login_admin(create(:admin))
        subject
        success
      end
    end
    context "when showing a banned tag" do
      let(:tag) { create(:banned) } 

      subject { get :show, params: { id: tag.name } }
      let(:success) do
        expect(response).to have_http_status(:success)
      end

      it "displays the tag information page for admins" do
        fake_login_admin(create(:admin))
        subject
        success
      end

      it "redirects with an error when not an admin" do
        get :show, params: { id: tag.name }
        it_redirects_to_with_error(tag_wranglings_path,
                                   "Please log in as admin")
      end
    end
    context "when tag doesn't exist" do
      it "raises an error" do
        expect do
          get :show, params: { id: "notatag" }
        end.to raise_error ActiveRecord::RecordNotFound
      end
    end
  end
  
  describe "show_hidden" do
    let(:work) { create(:work) }

    it "redirects to referer with an error for non-ajax warnings requests" do
      referer = tags_path
      request.headers["HTTP_REFERER"] = referer
      get :show_hidden, params: { creation_type: "Work", tag_type: "warnings", creation_id: work.id }
      it_redirects_to_with_error(referer, "Sorry, you need to have JavaScript enabled for this.")
    end

    it "redirects to referer with an error for non-ajax freeforms requests" do
      referer = tags_path
      request.headers["HTTP_REFERER"] = referer
      get :show_hidden, params: { creation_type: "Work", tag_type: "freeforms", creation_id: work.id }
      it_redirects_to_with_error(referer, "Sorry, you need to have JavaScript enabled for this.")
    end
  end

  describe "edit" do
    context "when editing a banned tag" do
      let(:tag) { create(:banned) } 

      subject { get :edit, params: { id: tag.name } }
      let(:success) do
        expect(response).to have_http_status(:success)
      end

      it_behaves_like "an action only authorized admins can access", authorized_roles: wrangling_read_access_roles

      it "redirects with an error when not an admin" do
        get :edit, params: { id: tag.name }
        it_redirects_to_with_error(tag_wranglings_path,
                                   "Please log in as admin")
      end
    end
    
    context "when tag doesn't exist" do
      it "raises an error" do
        expect do
          get :edit, params: { id: "notatag" }
        end.to raise_error ActiveRecord::RecordNotFound
      end
    end
  end

  describe "update" do
    context "setting a new type for the tag" do
      let(:unsorted_tag) { create(:unsorted_tag) }

      before do
        put :update, params: { id: unsorted_tag, tag: { type: "Fandom" }, commit: "Save changes" }
      end

      it "changes the tag type and redirects" do
        it_redirects_to_with_notice(edit_tag_path(unsorted_tag), "Tag was updated.")
        expect(Tag.find(unsorted_tag.id).class).to eq(Fandom)

        put :update, params: { id: unsorted_tag, tag: { type: "UnsortedTag" }, commit: "Save changes" }
        it_redirects_to_with_notice(edit_tag_path(unsorted_tag), "Tag was updated.")
        # The tag now has the original class, we can reload the original record without error.
        unsorted_tag.reload
      end

      include_examples "set last wrangling activity"
    end

    context "when making a canonical tag into a synonym" do
      let(:tag) { create(:freeform, canonical: true) }
      let(:synonym) { create(:freeform, canonical: true) }

      context "when logged in as a wrangler" do
        it "errors and renders the edit page" do
          put :update, params: { id: tag, tag: { syn_string: synonym.name }, commit: "Save changes" }
          expect(response).to render_template(:edit)
          expect(assigns[:tag].errors.full_messages).to include("Only an admin can make a canonical tag into a synonym of another tag.")

          tag.reload
          expect(tag.merger_id).to eq(nil)
        end
      end

      subject { put :update, params: { id: tag, tag: { syn_string: synonym.name }, commit: "Save changes" } }
      let(:success) do
        it_redirects_to_with_notice(edit_tag_path(tag), "Tag was updated.")
        tag.reload
        expect(tag.merger_id).to eq(synonym.id)
      end

      it_behaves_like "an action only authorized admins can access", authorized_roles: wrangling_full_access_roles
      
    end

    shared_examples "success message" do
      it "shows a success message" do
        expect(flash[:notice]).to eq("Tag was updated.")
      end
    end

    describe "adding a new associated tag" do
      let(:tag) { create(:character, canonical: true) }
      let(:associated) { nil } # to be overridden by the examples
      let(:field) { "#{associated.type.downcase}_string" }

      before do
        put :update, params: {
          id: tag.name, tag: { "#{field}": associated.name }
        }

        tag.reload
      end

      shared_examples "invalid association" do
        it "doesn't add the associated tag" do
          expect(tag.parents).not_to include(associated)
          expect(tag.children).not_to include(associated)
        end
      end

      context "when the associated tag doesn't exist" do
        let(:associated) do
          destroyed_fandom = create(:fandom)
          destroyed_fandom.destroy
          destroyed_fandom
        end

        it "has a useful error" do
          expect(assigns[:tag].errors.full_messages).to include(
            "Cannot add association to '#{associated.name}': " \
            "Common tag does not exist."
          )
        end

        include_examples "invalid association"
      end

      context "when the associated tag is entered into the wrong field" do
        let(:associated) { create(:fandom, canonical: true) }
        let(:field) { "relationship_string" }

        it "has a useful error" do
          expect(assigns[:tag].errors.full_messages).to include(
            "Cannot add association to '#{associated.name}': " \
            "#{associated.type} added in Relationship field."
          )
        end

        include_examples "invalid association"
      end

      context "when the associated tag has an invalid type" do
        # NOTE: This will enter the associated tag into the freeform_string
        # field, which is not displayed on the form. This still might come up
        # in the extremely rare case where a tag wrangler loads the form, a
        # different tag wrangler goes in and changes the type of the tag being
        # edited, and then the first wrangler submits the form.
        let(:associated) { create(:freeform, canonical: true) }

        it "has a useful error" do
          expect(assigns[:tag].errors.full_messages).to include(
            "Cannot add association to '#{associated.name}': A tag of type " \
            "#{tag.type} cannot have a child of type #{associated.type}."
          )
        end

        include_examples "invalid association"
      end

      context "when the associated tag has a valid type" do
        context "when the tag is a canonical child" do
          let(:associated) { create(:relationship, canonical: true) }

          include_examples "success message"
          include_examples "set last wrangling activity"

          it "adds the association" do
            expect(tag.parents).not_to include(associated)
            expect(tag.children).to include(associated)
          end
        end

        context "when the tag is a non-canonical child" do
          let(:associated) { create(:relationship, canonical: false) }

          include_examples "success message"
          include_examples "set last wrangling activity"

          it "adds the association" do
            expect(tag.parents).not_to include(associated)
            expect(tag.children).to include(associated)
          end
        end

        context "when the tag is a canonical parent" do
          let(:associated) { create(:fandom, canonical: true) }

          include_examples "success message"
          include_examples "set last wrangling activity"

          it "adds the association" do
            expect(tag.parents).to include(associated)
            expect(tag.children).not_to include(associated)
          end
        end

        context "when the tag is a non-canonical parent" do
          let(:associated) { create(:fandom, canonical: false) }

          it "has a useful error" do
            expect(assigns[:tag].errors.full_messages).to include(
              "Cannot add association to '#{associated.name}': " \
              "Parent tag is not canonical."
            )
          end

          include_examples "invalid association"
        end
      end
    end

    describe "adding a new metatag" do
      let(:tag) { create(:freeform, canonical: true) }
      let(:meta) { nil } # to be overridden by the examples

      before do
        put :update, params: {
          id: tag.name, tag: { meta_tag_string: meta.name }
        }

        tag.reload
      end

      shared_examples "invalid metatag" do
        it "doesn't add the metatag" do
          expect(tag.meta_tags).not_to include(meta)
        end
      end

      context "when the tag is not canonical" do
        let(:meta) { create(:freeform, canonical: false) }

        it "has a useful error" do
          expect(assigns[:tag].errors.full_messages).to include(
            "Invalid metatag '#{meta.name}': " \
            "Meta taggings can only exist between canonical tags."
          )
        end

        include_examples "invalid metatag"
      end

      context "when the tag is the wrong type" do
        let(:meta) { create(:character, canonical: true) }

        it "has a useful error" do
          expect(assigns[:tag].errors.full_messages).to include(
            "Invalid metatag '#{meta.name}': " \
            "Meta taggings can only exist between two tags of the same type."
          )
        end

        include_examples "invalid metatag"
      end

      context "when the metatag is itself" do
        let(:meta) { tag }

        it "has a useful error" do
          expect(assigns[:tag].errors.full_messages).to include(
            "Invalid metatag '#{meta.name}': " \
            "A tag can't be its own metatag."
          )
        end

        include_examples "invalid metatag"
      end

      context "when the metatag is its subtag" do
        let(:meta) do
          sub = create(:freeform, canonical: true)
          MetaTagging.create(meta_tag: tag, sub_tag: sub, direct: true)
          tag.reload
          sub.reload
        end

        it "has a useful error" do
          expect(assigns[:tag].errors.full_messages).to include(
            "Invalid metatag '#{meta.name}': " \
            "A metatag can't be its own grandparent."
          )
        end

        include_examples "invalid metatag"
      end

      context "when the metatag is already its grandparent" do
        let(:meta) do
          parent = create(:freeform, canonical: true)
          grandparent = create(:freeform, canonical: true)

          parent.sub_tags << tag
          parent.meta_tags << grandparent

          # We want to add the grandparent as our new metatag.
          grandparent
        end

        include_examples "success message"
        include_examples "set last wrangling activity"

        it "marks the formerly inherited meta tagging as direct" do
          expect(MetaTagging.find_by(sub_tag: tag, meta_tag: meta).direct).to be_truthy
        end
      end
    end

    it "can add and remove metatags at the same time" do
      old_metatag = create(:canonical_freeform)
      new_metatag = create(:canonical_freeform)

      tag = create(:canonical_freeform)
      create(:meta_tagging, meta_tag: old_metatag, sub_tag: tag, direct: true)
      old_metatag.reload
      tag.reload

      put :update, params: { id: tag.name, tag: { associations_to_remove: [old_metatag.id], meta_tag_string: new_metatag.name } }
      expect(tag.reload.direct_meta_tags).to eq [new_metatag]
    end

    context "recategorizing a tag to media" do
      let(:unsorted_tag) { create(:unsorted_tag) }
      let(:subject) { put :update, params: { id: unsorted_tag, tag: { type: "Media" }, commit: "Save changes" } }

      context "as a wrangler" do
        it "doesn't change the tag type and redirects" do
          subject

          it_redirects_to_with_notice(edit_tag_path(unsorted_tag), "Tag was updated.")
          expect(unsorted_tag.reload.class).to eq(UnsortedTag)
        end
      end

      context "as an admin" do
        let(:admin) { create(:superadmin) }

        before { fake_login_admin(admin) }

        it "changes the tag type and redirects" do
          subject

          it_redirects_to_with_notice(edit_tag_path(unsorted_tag), "Tag was updated.")
          expect(Tag.find(unsorted_tag.id).class).to eq(Media)
        end
      end
    end
  end

  describe "GET #index" do
    let(:collection) { create(:collection) }

    it "assigns subtitle with collection title and tags" do
      get :index, params: { collection_id: collection.name }
      expect(assigns[:page_subtitle]).to eq("#{collection.title} - Tags")
    end

    context "ArchiveConfig.FANDOM_NO_TAG_NAME exists and has tags" do
      let!(:no_fandom) { create(:fandom, name: ArchiveConfig.FANDOM_NO_TAG_NAME, canonical: true) }
      let!(:freeform1) { create(:freeform, canonical: true) }
      let!(:freeform2) { create(:freeform, canonical: true) }

      before do
        CommonTagging.create!(filterable: no_fandom, common_tag: freeform1)
        CommonTagging.create!(filterable: no_fandom, common_tag: freeform2)

        FilterCount.create!(
          filter: freeform1,
          public_works_count: 1,
          unhidden_works_count: 1
        )
        FilterCount.create!(
          filter: freeform2,
          public_works_count: 1,
          unhidden_works_count: 1
        )
      end

      it "assigns non-empty tags on /tags" do
        get :index

        expect(response).to have_http_status(:success)
        expect(response).to render_template(:index)
        expect(assigns(:tags)).to include(freeform1, freeform2)
      end

      it "assigns non-empty tags on /tags?show=random" do
        get :index, params: { show: :random }

        expect(response).to have_http_status(:success)
        expect(response).to render_template(:index)
        expect(assigns(:tags)).to include(freeform1, freeform2)
      end
    end

    context "ArchiveConfig.FANDOM_NO_TAG_NAME doesn't exist" do
      before do
        if (fandom = Fandom.find_by_name(ArchiveConfig.FANDOM_NO_TAG_NAME))
          fandom.destroy!
        end
      end

      it "does not 500 error on /tags" do
        get :index

        expect(response).to have_http_status(:success)
        expect(response).to render_template(:index)
        expect(assigns(:tags)).to be_empty
      end

      it "does not 500 error on /tags?show=random" do
        get :index, params: { show: :random }

        expect(response).to have_http_status(:success)
        expect(response).to render_template(:index)
        expect(assigns(:tags)).to be_empty
      end
    end
  end
end
