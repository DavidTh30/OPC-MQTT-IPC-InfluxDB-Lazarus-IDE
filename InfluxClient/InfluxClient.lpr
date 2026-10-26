program InfluxClient;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, tachartlazaruspkg, uinfluxclientmain, uinfluxapi;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'InfluxDB Client';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
