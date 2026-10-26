program InfluxSignalGen;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, usiggenmain, usiggen, uwaves, uinfluxapi;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'InfluxDB Signal Generator';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
