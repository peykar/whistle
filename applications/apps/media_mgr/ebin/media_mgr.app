{application,media_mgr,
             [{description,"Media Manager - Stream media via Shout from Couch"},
              {vsn,"0.0.1"},
              {modules,[media_mgr,media_mgr_app,media_mgr_sup,media_shout,
                        media_shout_sup,media_srv]},
              {registered,[]},
              {applications,[kernel,stdlib,crypto]},
              {mod,{media_mgr_app,[]}},
              {env,[]}]}.