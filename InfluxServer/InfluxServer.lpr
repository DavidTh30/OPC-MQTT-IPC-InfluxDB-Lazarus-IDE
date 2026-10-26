program InfluxServer;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, uinfluxmain, uinfluxhttp, uqueryexec, uinfluxql, utsdb, ulineproto;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'InfluxDB Server';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
