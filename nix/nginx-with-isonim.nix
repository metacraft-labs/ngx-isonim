{
  nginx,
  ngxIsOnimModule,
  writeTextFile,
  symlinkJoin,
  writeShellScriptBin,
}:

let
  # Create a wrapper nginx.conf that loads the module
  nginxConf = writeTextFile {
    name = "nginx-isonim-test.conf";
    text = ''
      load_module ${ngxIsOnimModule}/lib/ngx_http_isonim_module.so;

      worker_processes 1;
      error_log /tmp/ngx-isonim-test/error.log;
      pid /tmp/ngx-isonim-test/nginx.pid;

      events {
        worker_connections 64;
      }

      http {
        access_log /tmp/ngx-isonim-test/access.log;
        client_body_temp_path /tmp/ngx-isonim-test/client_body;
        proxy_temp_path /tmp/ngx-isonim-test/proxy;
        fastcgi_temp_path /tmp/ngx-isonim-test/fastcgi;
        uwsgi_temp_path /tmp/ngx-isonim-test/uwsgi;
        scgi_temp_path /tmp/ngx-isonim-test/scgi;

        server {
          listen 8088;
          location / {
            isonim_ssr on;
            isonim_ssr_app hello;
            isonim_ssr_hydration on;
          }
        }
      }
    '';
  };

  # Wrapper script that sets up temp dirs and runs nginx
  nginxWrapper = writeShellScriptBin "nginx-isonim" ''
    mkdir -p /tmp/ngx-isonim-test/{client_body,proxy,fastcgi,uwsgi,scgi}
    exec ${nginx}/bin/nginx -c ${nginxConf} -p /tmp/ngx-isonim-test "$@"
  '';
in
symlinkJoin {
  name = "nginx-with-isonim";
  paths = [
    nginxWrapper
    nginx
  ];
}
