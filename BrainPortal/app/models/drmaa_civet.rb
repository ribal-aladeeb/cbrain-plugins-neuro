
#A subclass of DrmaaTask to launch civet.
class DrmaaCivet < DrmaaTask

  Revision_info="$Id$"

  #See DrmaaTask.
  def self.has_args?
    true
  end
  
  #See DrmaaTask.
  def self.get_default_args(params = {}, saved_args = nil)
    file_ids         = params[:file_ids]

    userfiles = []
    file_ids.each do |id|
      userfiles << Userfile.find(id)
    end

    # MODE A, we have a single FileCollection in argument
    if userfiles.size == 1 && userfiles[0].is_a?(FileCollection)
      return get_default_args_for_collection(params,userfiles[0], saved_args)
    end

    # MODE B, we have one or many T1s in argument
    if userfiles.detect { |u| ! u.is_a?(SingleFile) }
      cb_error "Error: CIVET can only be launched on one FileCollection\n" +
               "or a set of T1 Minc files\n"
    end
    
    return get_default_args_for_t1list(params, userfiles, saved_args)
  end

  def self.get_default_args_for_t1list(params, userfiles, saved_args)

    user_id          = params[:user_id]
    bourreau_id      = params[:bourreau_id]
    data_provider_id = params[:data_provider_id]

    file_args = []

    all_files_I_can_access = Userfile.find_all_accessible_by_user(User.find(user_id))
    index_of_my_files      = all_files_I_can_access.index_by(&:name)

    userfiles.each do |t1|

      t1_name = t1.name
      t1_id   = t1.id
      (t2_id, pd_id, mk_id) = find_t2_pd_mask(t1_name,index_of_my_files)

      if t1_name.match(/(\w+)_(\w+)_t1\b/i)
        prefix = Regexp.last_match[1]
        dsid   = Regexp.last_match[2]
      else
        prefix = "prefix"
        dsid   = "dsid"
      end

      file_args << {
        :launch              => true,

        :t1_name             => t1_name,

        :t1_id               => t1_id,
        :t2_id               => t2_id,
        :pd_id               => pd_id,
        :mk_id               => mk_id,

        :prefix              => prefix,      # -prefix
        :dsid                => dsid,        #
        
        :multispectral       => false,       # -multispectral for true
        :spectral_mask       => false,       # -spectral-mask for true
      }
    end

    {  :file_args        => file_args,
       :civet_args       => get_common_civet_args(saved_args),

       :collection_id    => nil,
       :data_provider_id => data_provider_id,
       :bourreau_id      => bourreau_id,
    }
  end

  def self.get_default_args_for_collection(params, collection, saved_args)

    user_id          = params[:user_id]
    bourreau_id      = params[:bourreau_id]
    data_provider_id = params[:data_provider_id]

    collection_id = collection.id

    # TODO: Provide the link directly in the CIVET args page?
    state = collection.local_sync_status
    cb_error "Error: in order to process this collection, it must first have been synchronized.\n" +
          "In the file manager, click on the collection then on the 'synchronize' link." if
          ! state || state.status != "InSync"

    # Get the list of all files inside the collection; we only
    # look one level deep inside the directory.
    files_inside  = collection.list_files.map(&:name).select { |f| f !~ /\/\.*\// }
    files_inside  = files_inside.map { |f| f.sub(/^.*\//,"") }

    # Parse the list of all files and extract the MINC files.
    # We ignore everything else.
    minc_files = []
    files_inside.each do |basename|
      minc_files << basename if basename.match(/\.mnc(\.gz|\.Z)?$/i)
    end

    cb_error "There are no MINC files in this FileCollection!" unless minc_files.size > 0

    # From the list of minc files, try to identify files
    # that are clearly 't1' files, based on the filename.
    t1_files = []
    minc_files.each do |minc|
      t1_files << minc if minc.match(/_t1\b/i)
    end

    # If we have any, we remove them from the total list of minc files.
    minc_files = minc_files - t1_files

    # Prepare the structure for all the CIVET operation;
    # each CIVET has a mandatory t1, and optional t2, pd and mk.
    minc_groups = []  #  [ t1, t2, pd, mk ]

    # For properly named t1 files, try to also find
    # the optional t2, pd and masks files; if they are
    # found they are extracted from the list of minc files
    t1_files.each do |t1|
      (t2,pd,mk,minc_files) = extract_t2_pd_mask(t1,minc_files) # modifies array minc_files
      minc_groups << [ t1, t2, pd, mk ]
    end

    # For all remaining minc files, we assume they are t1s
    # and we process them without any t2, pd and mk.
    minc_files.each do |minc|
      next if minc.match(/_(t2|pd|mask)\b/i)  # ignore spurious t2s, pds, and masks
      minc_groups << [ minc, nil, nil, nil ]
    end
   
    # OK, build a arg structure for each minc group
    file_args = []
    minc_groups.each do |group|

      t1_name = group[0]
      t2_name = group[1]
      pd_name = group[2]
      mk_name = group[3]

      if t1_name.match(/(\w+)_(\w+)_t1\b/i)
        prefix = Regexp.last_match[1]
        dsid   = Regexp.last_match[2]
      else
        prefix = "prefix"
        dsid   = "dsid"
      end

      file_args << {
        :launch              => true,

        :t1_name             => t1_name,
        :t2_name             => t2_name,
        :pd_name             => pd_name,
        :mk_name             => mk_name,

        :prefix              => prefix,      # -prefix
        :dsid                => dsid,        #
        
        :multispectral       => false,       # -multispectral for true
        :spectral_mask       => false,       # -spectral-mask for true
      }

    end

    {  :file_args        => file_args,
       :civet_args       => get_common_civet_args(saved_args),

       :collection_id    => collection_id,
       :data_provider_id => data_provider_id,
       :bourreau_id      => bourreau_id,
    }
  end

  # Returns the sceintific parameters common to all the CIVET
  # jobs we're about to launch
  def self.get_common_civet_args(saved_args)
    civet_args = saved_args || {
      :make_graph          => false,       # -make-graph for true
      :make_filename_graph => false,       # -make-filename-graph for true
      :print_status_report => false,       # -print-status-report for true

      :template            => '1.00',      # -template
      :model               => 'icbm152nl', # -model
        
      :correct_pve         => false,       # -[no-]correct-pve
        
      :interp              => 'trilinear', # -interp
      :N3_distance         => 200,         # -N3-distance
      :lsq                 => '9',         # -lsq6, -lsq9, -lsq12
      :no_surfaces         => false,       # -no-surfaces
      :thickness_method    => 'tlink',     # -thickness method kernel
      :thickness_kernel    => 20,          #             "
      :resample_surfaces   => false,       # -[no-]resample-surfaces
      :combine_surfaces    => false,       # -[no-]combine-surfaces

      # VBM options
      :VBM                 => false,       # -[no-]VBM
      :VBM_fwhm            => '8',         # -VBM-fwhm
      :VBM_symmetry        => false,       # -[no-]VBM-symmetry
      :VBM_cerebellum      => true,        # -[no-]VBM-cerebellum

      # Not yet implemented in interface
      :animal              => false,       # -[no-]animal
      :atlas               => 'lobe'       # -symmetric-atlas or -lobe-atlas
      # TODO animal-atlas-dir
    }
    civet_args
  end
  
  #See DrmaaTask.
  def self.launch(params)
    civet_args = params[:civet_args]
    file_args  = params[:file_args] || {}

    # file_args is not the same struct as above in default_args, so
    # transform it back into an array of records (in the values)
    file_args  = file_args.values
    params[:file_args] = file_args

    file_args  = file_args.select { |f| f[:launch] }
    if file_args.empty?
      return "No CIVET started, as no T1 file selected for launch!"
    end

    study_name = params[:study_name] || ""
    qc_study   = params[:qc_study]   || false
    if ! study_name.blank? && ! Userfile.is_legal_filename?(study_name)
      return "Sorry, but the study name provided contains some unacceptable characters."
    end

    flash = "" # message accumulator
    user = User.find(params[:user_id])

    spawn_this = file_args.size > 3

    CBRAIN.spawn_with_active_records_if(spawn_this,user,"CIVET launcher") do
      tids = []
      file_args.each do |file|
        tids << self.launch_one(params,file,civet_args)
        flash += "Started CIVET on file '#{file[:t1_name]}'.\n" unless spawn_this
      end
      unless study_name.blank?
        cid,cmess = launch_combiner(params,study_name,tids)
        qid,qmess = launch_qc(params,cid) unless qc_study.blank?
        flash += cmess if cmess
        flash += qmess if qmess
      end
    end
    flash += "Started CIVET on #{file_args.size} files.\n" if spawn_this
    
    flash
  end

  def self.launch_one(params,one_file_args,civet_args)
    user_id          = params[:user_id]
    collection_id    = params[:collection_id] # can be nil
    bourreau_id      = params[:bourreau_id]
    data_provider_id = params[:data_provider_id]
    description      = params[:description]
    fake_colid       = params[:fake_run_civetcollection_id]

    collection_id   = nil if collection_id.blank?
    collection      = collection_id ? FileCollection.find(collection_id) : nil

    extended_args = civet_args.dup
    extended_args[:data_provider_id] = data_provider_id
    extended_args[:collection_id]    = collection_id # can be nil
    extended_args[:fake_run_civetcollection_id] = fake_colid unless fake_colid.blank?

    # For logging
    t1_object = collection || Userfile.find(one_file_args[:t1_id])
    t1_name   = collection ? one_file_args[:t1_name] : t1_object.name
    description = t1_name if description.blank?

    # Create the object, send it to Bourreau
    civ = DrmaaCivet.new  # a blank ActiveResource object
    civ.user_id      = user_id
    civ.bourreau_id  = bourreau_id unless bourreau_id.blank?
    civ.description  = description
    civ.params       = extended_args.merge(one_file_args)
    civ.save

    # Log the task info in the source object
    if collection
      t1_object.addlog_context(self,"Sent '#{t1_name}' to CIVET, task #{civ.bname_tid}")
    else
      t1_object.addlog_context(self,"Sent to CIVET, task #{civ.bname_tid}")
    end

    return civ.id

  end
  
  #See DrmaaTask.
  def self.save_options(params)
    params[:civet_args]
  end
  
  private

  def self.find_t2_pd_mask(t1_name,userfileindex) #:nodoc:
      if ! t1_name.match(/_t1\b/)
          return [nil,nil,nil]
      end
      t2 = userfileindex[t1_name.sub(/_t1/,"_t2")]
      t2_id = t2 ? t2.id : nil

      pd = userfileindex[t1_name.sub(/_t1/,"_pd")]
      pd_id = pd ? pd.id : nil

      mk = userfileindex[t1_name.sub(/_t1/,"_mask")]
      mk_id = mk ? mk.id : nil

      [t2_id,pd_id,mk_id]
  end

  def self.extract_t2_pd_mask(t1,minclist)  #:nodoc:
    t2_name = nil
    pd_name = nil
    mk_name = nil

    expect = t1.sub("_t1","_t2")
    t2_name = expect if minclist.include?(expect)
      
    expect = t1.sub("_t1","_pd")
    pd_name = expect if minclist.include?(expect)
      
    expect = t1.sub("_t1","_mask")
    mk_name = expect if minclist.include?(expect)
      
    minclist = minclist - [ t2_name, pd_name, mk_name ]

    [ t2_name, pd_name, mk_name, minclist ]
  end

  def self.launch_combiner(params,study_name,tids)
    
    combiner = DrmaaCivetCombiner.new
    combiner.user_id          = params[:user_id]
    combiner.bourreau_id      = params[:bourreau_id] if params[:bourreau_id]
    combiner.description      = params[:study_name]
    combiner.params = {
      :civet_study_name     => study_name,
      :civet_from_task_ids  => tids.join(","),
      :destroy_sources      => false  # must be the string 'YeS' to trigger it
    }
    combiner.params[:data_provider_id] = params[:data_provider_id] if params[:data_provider_id]

    tids.each do |tid|
      combiner.add_prerequisites_for_setup(tid)
    end

    combiner.save
    return [combiner.id, "Launched CivetCombiner with Prerequisites\n"]

  end

  def self.launch_qc(params,cid)

    qc = DrmaaCivetQc.new
    qc.user_id     = params[:user_id]
    qc.description = params[:study_name]
    qc.params      = { :study_from_task_id => cid }
    qc.bourreau_id = params[:bourreau_id] if params[:bourreau_id]
    qc.add_prerequisites_for_setup(cid)
    qc.save

    return [qc.id, "Launched CivetQc with Prerequisites\n"]

  end

end

