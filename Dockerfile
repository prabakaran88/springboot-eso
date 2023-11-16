FROM openjdk:17
COPY target/springboot-eso.jar springboot-eso.jar
EXPOSE 8080
ENTRYPOINT ["java","-jar","/springboot-eso.jar"]