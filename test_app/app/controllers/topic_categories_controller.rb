class TopicCategoriesController < ApplicationController
  # GET /topic_categories
  # GET /topic_categories.xml
  def index
    @topic_categories = TopicCategory.all

    respond_to do |format|
      format.html # index.html.erb
      format.xml  { render :xml => @topic_categories }
    end
  end

  # GET /topic_categories/1
  # GET /topic_categories/1.xml
  def show
    @topic_category = TopicCategory.find(params[:id])

    respond_to do |format|
      format.html # show.html.erb
      format.xml  { render :xml => @topic_category }
    end
  end

  # GET /topic_categories/new
  # GET /topic_categories/new.xml
  def new
    @topic_category = TopicCategory.new

    respond_to do |format|
      format.html # new.html.erb
      format.xml  { render :xml => @topic_category }
    end
  end

  # GET /topic_categories/1/edit
  def edit
    @topic_category = TopicCategory.find(params[:id])
  end

  # POST /topic_categories
  # POST /topic_categories.xml
  def create
    @topic_category = TopicCategory.new(params[:topic_category])

    respond_to do |format|
      if @topic_category.save
        flash[:notice] = 'TopicCategory was successfully created.'
        format.html { redirect_to(@topic_category) }
        format.xml  { render :xml => @topic_category, :status => :created, :location => @topic_category }
      else
        format.html { render :action => "new" }
        format.xml  { render :xml => @topic_category.errors, :status => :unprocessable_entity }
      end
    end
  end

  # PUT /topic_categories/1
  # PUT /topic_categories/1.xml
  def update
    @topic_category = TopicCategory.find(params[:id])

    respond_to do |format|
      if @topic_category.update_attributes(params[:topic_category])
        flash[:notice] = 'TopicCategory was successfully updated.'
        format.html { redirect_to(@topic_category) }
        format.xml  { head :ok }
      else
        format.html { render :action => "edit" }
        format.xml  { render :xml => @topic_category.errors, :status => :unprocessable_entity }
      end
    end
  end

  # DELETE /topic_categories/1
  # DELETE /topic_categories/1.xml
  def destroy
    @topic_category = TopicCategory.find(params[:id])
    @topic_category.destroy

    respond_to do |format|
      format.html { redirect_to(topic_categories_url) }
      format.xml  { head :ok }
    end
  end
end
