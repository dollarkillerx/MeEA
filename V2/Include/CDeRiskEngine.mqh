#ifndef C_DERISK_ENGINE_MQH
#define C_DERISK_ENGINE_MQH

class CDeRiskEngine
{
private:
   double m_stepTrendMult;
   double m_stepMinPoints;
   double m_stepMaxPoints;

   bool m_hasAnchor;
   double m_anchorPrice;
   int m_anchorDir;

public:
   CDeRiskEngine() : m_stepTrendMult(1.4), m_stepMinPoints(80.0), m_stepMaxPoints(180.0),
      m_hasAnchor(false), m_anchorPrice(0.0), m_anchorDir(0) {}

   void Init(double stepTrendMult, double stepMinPoints, double stepMaxPoints)
   {
      m_stepTrendMult = stepTrendMult;
      m_stepMinPoints = stepMinPoints;
      m_stepMaxPoints = stepMaxPoints;
   }

   double GetTrendStepPoints(double atrPoints) const
   {
      double step = atrPoints * m_stepTrendMult;
      if(step < m_stepMinPoints) step = m_stepMinPoints;
      if(step > m_stepMaxPoints) step = m_stepMaxPoints;
      return step;
   }

   void OnTrendEnter(double currentPrice, int trendDir)
   {
      m_hasAnchor = true;
      m_anchorPrice = currentPrice;
      m_anchorDir = trendDir;
   }

   void OnTrendExit()
   {
      m_hasAnchor = false;
      m_anchorPrice = 0.0;
      m_anchorDir = 0;
   }

   bool StepTriggered(double currentPrice, double stepPoints) const
   {
      if(!m_hasAnchor || stepPoints <= 0.0)
         return false;

      double distPoints = MathAbs(currentPrice - m_anchorPrice) / _Point;
      return (distPoints >= stepPoints);
   }

   void AdvanceAnchor(double stepPoints)
   {
      if(!m_hasAnchor || m_anchorDir == 0 || stepPoints <= 0.0)
         return;

      double shift = m_anchorDir * stepPoints * _Point;
      m_anchorPrice += shift;
   }

   bool HasAnchor() const { return m_hasAnchor; }
   double GetAnchorPrice() const { return m_anchorPrice; }
   int GetAnchorDir() const { return m_anchorDir; }
};

#endif
